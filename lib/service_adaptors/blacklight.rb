require 'nokogiri'
require 'open-uri'
require 'base64'
require 'marc'

# Searches a Blacklight with the cql extension installed.
#
# 
# Params include:
# [base_url]
#    required. Complete URL to catalog.atom. Eg "https://blacklight.mse.jhu.edu/catalog.atom"
# [bl_fields]
#    required with at least some entries if you want this to do anything. Describe the names of given semantic fields in your BL instance.
#    * issn
#    * isbn
#    * lccn
#    * oclcnum
#    * id (defaults to 'id')
#    * title
#    * author
#    * serials_limit_clause => not an index name, full URL clause for a limit to apply to known serials searches, for instance "f[format][]=Serial"
# [identifier_search]
#    Do catalog search on issn/isbn/oclcnum/lccn/bibId. Default true.
# [keyword_search]
#    Do catalog search on title/author keywords where applicable. Generally only used when identifier_search finds no hits, if identifier_search is on. Default true. 
# [keyword_per_page]
#    How many records to fetch from blacklight when doing keyword searches.
# [exclude_holdings]
#    Can be used to exclude certain 'dummy' holdings that have certain collection, location, or other values. Eg:
#    exclude_holdings:
#      collection_str:
#        - World Wide Web
#        - Internet
# [rft_id_bibnum_prefixes]
#    Array of URI prefixes in an rft_id that indicate that the actual solr id comes next. For instance, if your blacklight will send "http://blacklight.com/catalog/some_id" in an rft_id, then include "http://blacklight.com/catalog/". Optional.
class Blacklight < Service
  required_config_params :base_url, :display_name
  attr_reader :base_url, :cql_search_field
  attr_reader :bl_fields, :issn

  include UmlautHttp
  include MetadataHelper
  include MarcHelper
  include XmlSchemaHelper

  def initialize(config)
    # defaults    
    # If you are sending an OpenURL from a library service, you may
    # have the HIP bibnum, and include it in the OpenURL as, eg.
    # rft_id=http://catalog.library.jhu.edu/bib/343434 (except URL-encoded)
    # Then you'd set rft_id_bibnum_prefix to http://catalog.library.jhu.edu/bib/
    @rft_id_bibnum_prefixes = []
    @cql_search_field = "cql"
    @keyword_per_page = 10
    @identifier_search = true
    @keyword_search = true
    super(config)
    @bl_fields = { "id" => "id "}.merge(@bl_fields)
  end

  # Standard method, used by background service updater. See Service docs. 
  def service_types_generated    
    types = [ ServiceTypeValue[:fulltext], ServiceTypeValue[:holding], ServiceTypeValue[:table_of_contents], ServiceTypeValue[:relevant_link] ]
    
    return types
  end


  def handle(request)        
    ids_processed = []
    
    if (@identifier_search && url = blacklight_precise_search_url(request) )
      doc = Nokogiri::XML( http_fetch(url).body )
      
      ids_processed.concat( bib_ids_from_atom_entries( doc.xpath("atom:feed/atom:entry", xml_ns) ) )
  
      # namespaces make xpath harder than it should be, but css
      # selector still easy, thanks nokogiri! Grab the marc from our
      # results. 
      marc_matches = doc.xpath("atom:feed/atom:entry/atom:content[@type='application/marc']", xml_ns).collect do |encoded_marc21|
        MARC::Reader.decode( Base64.decode64(encoded_marc21.text) )        
      end
  
      add_856_links(request, marc_matches )
  
      # Got to make a second fetch for dlf_expanded info, cause BL doens't
      # (yet) let us ask for more than one at once
      holdings_url = blacklight_precise_search_url( request, "dlf_expanded" )
      add_holdings( holdings_url )
  
      
      
    end
      
    #keyword search.    
    if (@keyword_search &&
        url = blacklight_keyword_search_url(request))
        doc = Nokogiri::XML( http_fetch(url).body )
        # filter out matches whose titles don't really match at all, or
        # which have already been seen in identifier search. 
        entries = filter_keyword_entries( doc.xpath("atom:feed/atom:entry", xml_ns) , :exclude_ids => ids_processed )

        marc_by_atom_id = {}
        
        # namespaces make xpath harder than it should be, but css
        # selector still easy, thanks nokogiri! Grab the marc from our
        # results. 
        marc_matches = entries.xpath("//atom:feed/atom:entry/atom:content[@type='application/marc']", xml_ns).collect do |encoded_marc21|
          marc = MARC::Reader.decode( Base64.decode64(encoded_marc21.text) )

          marc_by_atom_id[ encoded_marc21.at_xpath("ancestor::atom:entry/atom:id/text()", xml_ns).to_s  ] = marc
          
          marc
        end
        debugger
       
        # We've filtered out those we consider just plain bad
        # matches, everything else we're going to call
        # an approximate match. Sort so that those with
        # a date close to our request date are first.
        if ( year = get_year(request.referent))
          marc_matches = marc_matches.partition {|marc| get_years(marc).include?( year )}.flatten
        end
        # And add in the 856's
        add_856_links(request, marc_matches, :match_reliability => ServiceResponse::MatchUnsure)

        # Fetch and add in the holdings
        url = blacklight_url_for_ids(bib_ids_from_atom_entries(entries))
        
        add_holdings( url, :match_reliability => ServiceResponse::MatchUnsure, :marc_data => marc_by_atom_id ) if url
    end
      
    
    
    return request.dispatched(self, true)


  end

  # Send a CQL request, for an atom response with embedded marc21 please
  def blacklight_precise_search_url(request, format = "marc")
    # Add search clauses for our identifiers, if we have them and have a configured search field for them. 
    clauses = []
    ["issn", "lccn", "isbn", "oclcnum"].each do |key|
      clauses.push( "#{bl_fields[key]} = \"#{request.referent.send(key)}\"") if bl_fields[key] && request.referent.send(key)
    end
    # Add Solr document identifier if we can get one from the URL
    
    if (id = get_solr_id(request.referent))
      clauses.push("#{bl_fields['id']} = \"#{id}\"")
    end
    
    # if we have nothing, we can do no search.
    return nil if clauses.length == 0
    
    cql = clauses.join(" OR ")
    
    return base_url + "?search_field=#{@cql_search_field}&content_format=#{format}&q=#{CGI.escape(cql)}"             
  end

  def blacklight_keyword_search_url(request, format="marc")
    
    clauses = []

    # phrase search for title, just raw dismax for author
    title = get_search_title(request.referent)
    return nil unless title
    # Embed quotes inside the quoted value, need to backslash-quote for CQL,
    # and backslash the backslashes for ruby literal. 
    clauses.push("#{@bl_fields["title"]} = \"\\\"#{title}\\\"\"")
    if (author = get_top_level_creator(request.referent))
      clauses.push("#{@bl_fields["author"]} = \"#{author}\"")
    end

    
    url = base_url + "?search_field=#{@cql_search_field}&content_format=#{format}&q=#{CGI.escape(clauses.join(" AND "))}"

    if (@bl_fields["serials_limit_clause"] &&
        title_is_serial?(request.referent))        
      url += "&" + @bl_fields["serials_limit_clause"]
    end
    
    return url
  end

  # Takes a url that will return atom response of dlf_expanded content.
  # Adds Umlaut "holding" ServiceResponses for dlf_expanded, as appropriate.
  # 
  def add_holdings(holdings_url, options = {})
    options[:match_reliability] ||= ServiceResponse::MatchExact
    options[:marc_data] ||= {}
    
    atom = Nokogiri::XML( http_fetch(holdings_url).body )
    content_entries = atom.search("/atom:feed/atom:entry/atom:content", xml_ns)
    
    # For each atom entry, find the dlf_expanded record. For each dlf_expanded
    # record, take all of it's holdingsrec's if it has them, or all of it's
    # items if it doesn't, and add them to list. We wind up with a list
    # of mixed holdingsrec's and items. 
    holdings_xml = content_entries.collect do |dlf_expanded|      
      copies = dlf_expanded.xpath("dlf:record/dlf:holdings/dlf:holdingset/dlf:holdingsrec", xml_ns)
      copies.length > 0 ? copies : dlf_expanded.xpath("dlf:record/dlf:items/dlf:item", xml_ns)
    end.flatten
    
    service_data = holdings_xml.collect do | xml_metadata |
      atom_entry = xml_metadata.at_xpath("ancestor::atom:entry", xml_ns)
      atom_id = atom_entry.at_xpath("atom:id/text()", xml_ns).to_s

      edition_str = edition_statement(options[:marc_data][atom_id])
      
      xml_to_holdings( xml_metadata ).merge(
        :service => self,
        :match_reliability => options[:match_reliability],
        :edition_str => edition_str,
        :url => atom_entry.at_xpath("atom:link[@rel='alternate'][@type='text/html']/attribute::href", xml_ns).to_s
      )
    end
    
    # strip out holdings that aren't really holdings
    service_data.delete_if do |data|
      @exclude_holdings.collect do |key, values|
        values.include?(data[key.to_sym])
      end.include?(true)
    end

    # Sort by "collection"
    service_data.sort do |a, b|
      a[:collection_str] <=> b[:collection_str]
    end
    
    service_data.each do |data|
      request.add_service_response(data.merge(:service => self), ["holding"])
    end
  end

  def filter_keyword_entries(atom_entries, options = {})
    options[:exclude_ids] ||= []
  
    request_title_forms = [
        raw_search_title(request.referent).downcase,
        normalize_title( raw_search_title(request.referent), :remove_subtitle => true),
        normalize_title( raw_search_title(request.referent) )
    ].compact

    # Only keep entries with title match, and that aren't in the
    # exclude_ids list. 
    good_entries = atom_entries.find_all do |atom_entry|
      title = atom_entry.xpath("atom:title/text()", xml_ns).to_s  
   
      entry_title_forms = [
        title.downcase,
        normalize_title(title, :remove_subtitle=>true),
        normalize_title(title)
      ].compact
      
      ((entry_title_forms & request_title_forms).length > 0 &&
       (bib_ids_from_atom_entries(atom_entry) & options[:exclude_ids]).length == 0)
    end
    return Nokogiri::XML::NodeSet.new( atom_entries.document, good_entries)
  end

  def bib_ids_from_atom_entries(entries)
    entries.xpath("atom:id/text()", xml_ns).to_a.collect do |atom_id|
          atom_id.to_s =~ /([^\/]+)$/
          $1
    end.compact
  end
  
  def blacklight_url_for_ids(ids, format="dlf_expanded")
    return nil unless ids.length > 0  
  
    return base_url + "?search_field=#{@cql_search_field}&content_format=#{format}&q=" + CGI.escape("#{@bl_fields["id"]} any \"#{ids.join(" ")}\"")
  end
    

  def get_solr_id(rft)
    rft.identifiers.each do |id|
      @rft_id_bibnum_prefixes.each do |prefix|
        if id[0, prefix.length] == prefix
          return id[prefix.length, id.length]
        end
      end
    end

    return nil    
  end

end
