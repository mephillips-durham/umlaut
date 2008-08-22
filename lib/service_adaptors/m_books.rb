# Service that searches MBooks from the University of Michigan
# Currently limited since it only searches by OCLCnum
#
# Most MBooks will also be in Google Books (but not neccesarily vice versa).
# However, U of M was more generous in deciding what books are public domain.
# Therefore the main expected use case is to use with Google Books, with
# MBooks being a lower priority, and suppress_if_gbs_fulltext set to true. 
#
# 
# Two possibilities are available for sdr rights "full" or "searchonly".
# The third possibility is that sdr will be null.
# 
# MBooks sometimes shows fulltext or search sometimes when GBS has lesser access
# FIXME Eventually this service will be able to offer search inside

class MBooks < Service
  require 'open-uri'
  require 'json'
  include MetadataHelper
  
  attr_reader :url, :display_name, :note, :suppress_if_gbs_fulltext
  
  # FIXME add search_inside later, which ought to be _very_ easy to do with MBooks
  def service_types_generated
    types = [ ServiceTypeValue[:fulltext] ]
    types << ServiceTypeValue[:highlighted_link] if @show_search_inside

    return types
  end
  
  def initialize(config)
    @url = 'http://mirlyn.lib.umich.edu/cgi-bin/sdrsmd?'
    @display_name = 'University of Michigan MBooks'
    @num_full_views = 1
    @note =  '' #'Fulltext books from the University of Michigan'
    @show_search_inside = false
    @suppress_if_gbs_fulltext = true
    super(config)
  end
  
  def handle(request)
    
    
    
    if ( @suppress_if_gbs_fulltext &&
         request.get_service_type("fulltext").find {|st|  st.service_response.service.class == GoogleBookSearch}   )
         
         RAILS_DEFAULT_LOGGER.debug("MBooks service: Aborting since GBS response already present")

         return request.dispatched(self, true)
    end
    
    get_viewability(request)
    return request.dispatched(self, true)
  end
  
  def get_viewability(request)    
    params = get_parameters(request.referent)
    return nil if params.nil?
    mb_response = do_query(params)
    c_response = clean_response(mb_response)
    return nil if c_response.nil?
    # FIXME once we can search for more than one identifier at a time we'll
    #   need to dedupe our resultset
    full_views_shown = create_fulltext_service_response(request, c_response)
    
    unless full_views_shown
      do_web_links(request, c_response)
    end
    
  end
  
  # just a wrapper around get_bibkey_parameters
  def get_parameters(rft)
    # FIXME currently the API only supports oclcnum
    get_bibkey_parameters(rft) do |isbn, lccn, oclcnum|      
      return nil if oclcnum.nil?
      'oclc=' << oclcnum          
    end
  end
  
  # method that takes a referent and a block for parameter creation
  # The block receives isbn, lccn, oclcnum and is responsible for formatting
  # the parameters for the particular service
  # FIXME consider moving this into metadata_helper
  def get_bibkey_parameters(rft)
    isbn = get_identifier(:urn, "isbn", rft)
    oclcnum = get_identifier(:info, "oclcnum", rft)
    lccn = get_identifier(:info, "lccn", rft)
        
    yield(isbn, lccn, oclcnum)    
  end
  
  # conducts query and parses the JSON
  def do_query(params)
    link = @url + params
    return JSON.parse( open(link).read )
  end
  
  # We're only interested in the 'sdr's and only those that have some rights
  def clean_response(resp)
    cleaned_response = []
    # because of the structure of the response we recurse through it to get
    # what we're after. OK, this is a bit of premature optimization since we
    # only have one response returned right now.
    resp['result'].each_value do |id_value|
      return nil if id_value.nil?
      id_value.each do |hit|
        cleaned_response << hit['sdr'] unless hit['sdr'].nil?
      end
    end
    cleaned_response
  end
  
  # FIXME abstract this out for use with both GBS and MBooks
  def create_fulltext_service_response(request, data)
    display_name = @display_name
    
    full_views = data.select{|d| d['rights'] == 'full'}
    return nil if full_views.empty?
    count = 0
    full_views.each do |fv|
      request.add_service_response(
        {:service=>self, 
          :display_text=>display_name, 
          :url=>fv['mburl'], 
          :notes=> @note}, 
        [ :fulltext ]) 
      count += 1
      break if count == @num_full_views
    end   
    return true
  end

  
  # other than full view MBooks only provides searchonly
  # FIXME until search inside is integrated into trunk create a link for this
  def do_web_links(request, data)
    search_views = data.select{|d| d['rights'] == 'searchonly'}
    return nil if search_views.blank? or not @show_search_inside
    
    search_view = search_views.first
    url = search_view['mburl']
    display_text = "Search Inside"
    #notes = search_view['handle']
    request.add_service_response( { 
        :service=>self,    
        :url=>url,
        :display_text=>display_text,
        :service_data => {
          #:notes => notes
          }},
      [ServiceTypeValue[:highlighted_link]]    ) 
  end
  
  
  # sample OCLCnums with appropriate results showing that we can pick up other
  #   resources by using this service
  # 02029914  MBooks: full, GBS: info with search inside
  # 01635828  MBooks: full, GBS: snippet
  # 55517975  MBooks: search, GBS: limited preview
  # 02299399  MBooks: full, GBS: snippet
  # 16857172  MBooks: full, GBS: info
  
end