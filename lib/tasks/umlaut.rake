
namespace :umlaut do
    desc "Perform nightly maintenance. Set up in cron."
    task :nightly_maintenance => [:load_sfx_urls, :expire_sessions, :expire_old_data]
  
  

    desc "Loads sfx_urls from SFX installation. SFX mysql login needs to be set in config."
    task :load_sfx_urls => :environment do

      if SfxDb.connection_configured?
    
        puts "Loading SFXUrls via direct access to SFX db."
        #sfxlcl41.TARGET_SERVICE
        # Check if we have an SFX3 schema, or if not use SFX4
        sfx3 = true
        begin
          SfxDb::Object.connection.select_all("SHOW FIELDS FROM TARGET_SERVICE")
        rescue ActiveRecord::StatementInvalid
          sfx3 = false
        end
        
        if sfx3
          urls = SfxDb::SfxDbBase.fetch_sfx_urls
        else
          urls = SearchMethods::Sfx4.fetch_sfx_urls
        end
        
        ignore_urls = UmlautController.umlaut_config.lookup!("sfx.sfx_load_ignore_hosts", [])
        
        # We only want the hostnames
        hosts = urls.collect do |u|
          begin
          uri = URI.parse(u)
          uri.host
          rescue Exception
          end
        end
        hosts.uniq!
        
        SfxUrl.transaction do
          SfxUrl.delete_all
          
          hosts.each {|h| SfxUrl.new({:url => h}).save! unless ignore_urls.find {|ignore| ignore === h }}      
        end
      else
        puts "Skipping load of SFXURLs via direct access to SFX db. No direct access is configured. Configure in config/umlaut_config/database.yml"
      end
    end

    desc "Expire sessions older than config.app_config.session_expire_seconds"
    task :expire_sessions => :environment do
      # Assume sessions are in db. 
      # Don't know good way to get the connection associated with sessions,
      # since there is no model. Assume Request is in the same db.
      expire_seconds = UmlautController.umlaut_config.lookup!("session_expire_seconds", 1.day)
      puts "Expiring sessions older than #{expire_seconds} seconds (set with config session_expire_seconds)."
      Request.connection.execute("delete from sessions where now() - updated_at > #{expire_seconds}")
    end


    desc "Cleanup of database for old data associated with expired sessions etc."
    task :expire_old_data => :environment do
      # There are requests, responses, and dispatched_service entries
      # hanging around for things that may be way old and no longer
      # need to hang around. How do we know if they're too old?
      # If they are no longer associated with any session, mainly.

      # Deleting things as aggressively as we're doing here doesn't leave
      # us much for statistics, but we aren't currently gathering any
      # statistics anyway. If statistics are needed, more exploration
      # is needed of performance vs. leaving things around for statistics. 

      # For efficiency, we delete with direct DB calls, so don't count
      # on Rails business logic being triggered! Was just WAY too slow
      # otherwise. Also, sorry, doing all this in a db efficient way (one db
      # query) requires some tricky SQL, which be MySQL specific. 

      # Current Umlaut never re-uses a request different between sessions, so
      # if the session is dead, we can purge the Requests too. Permalink
      # architecture has been fixed to not rely on requests or referents,
      # permalinks (post new architecture) store their own context object.

      puts "Deleting Requests no longer associated with a session."
      begin_time = Time.now
      work_clause = " FROM requests LEFT OUTER JOIN sessions ON requests.session_id = sessions.session_id WHERE sessions.id is null "
      count = Request.count_by_sql("SELECT count(*) " + work_clause)
      Request.connection.execute("DELETE requests " + work_clause)
      puts "  Deleted #{count} Requests in #{Time.now - begin_time}"

    


      
      # Now, let's get rid of any ServiceResponses that no longer have
      # Requests 
       
      puts "Deleting orphaned ServiceResponses...."
      begin_time = Time.now
        work_clause = " FROM service_responses WHERE NOT EXISTS (SELECT * FROM requests WHERE service_responses.request_id =  requests.id)"
      count = ServiceResponse.count_by_sql("SELECT count(*) " + work_clause)
      ServiceResponse.connection.execute("DELETE " + work_clause)  
      puts "  Deleted #{count} ServiceResponses in #{Time.now - begin_time}"

      
      # And get rid of DispatchedServices for 'dead' requests too. Don't
      # need em.
      puts "Deleting DispatchedServices for dead Requests..."
      begin_time = Time.now
      # Sorry, may be MySQL only. 
      work_clause = " FROM (dispatched_services LEFT OUTER JOIN requests ON dispatched_services.request_id = requests.id)  WHERE requests.id IS NULL  "
      count = DispatchedService.count_by_sql("SELECT count(*) " + work_clause)
      DispatchedService.connection.execute("DELETE dispatched_services " + work_clause)
      puts "  Deleted #{count} DispatchedServices in #{Time.now - begin_time}"
      

      # Turns out we need to get rid of old referents and referentvalues
      # too. There are just too many. Permalinks have been updated to
      # store their own info and not depend on Referent existing. 
      referent_expire = Time.now - UmlautController.umlaut_config.lookup!("referent_expire_seconds", 20.days)
      puts "Deleting Referents/ReferentValues older than #{referent_expire.inspect}"
      begin_time = Time.now
      # May be MySQL dependent. 
      Referent.connection.execute("DELETE referents, referent_values FROM referents, referent_values where referents.id = referent_values.referent_id AND referents.created_at < '#{referent_expire.to_formatted_s(:db)}'" )
      puts "  Deleted Referents in #{Time.now - begin_time}"
      
      # And turns out we have all Clickthroughs being stored for no apparent
      # reason, let's just delete any older than 3 months ago. 
      Clickthrough.destroy_all(['created_at < ?', 3.months.ago])
      puts "Deleted Clickthroughs older than 3 months"
              
    end
    
end