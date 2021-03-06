# All behavior from UmlautController is extracted into this module,
# so that we can generate a local UmlautController that includes
# this module, and local app can configure or over-ride default behavior. 
# 
module Umlaut::ControllerBehavior
  extend ActiveSupport::Concern
  
  include UmlautConfigurable
  include Umlaut::ErrorHandling
  include Umlaut::ControllerLogic
  
  included do |controller|
    controller.helper Umlaut::Helper # global umlaut view helpers
    
    # init default configuration values
    UmlautConfigurable.set_default_configuration!(controller.umlaut_config)
  end
  
  protected
  
  # Returns a Collection object with currently configured services. 
  # Loads from Rails.root/config/umlaut_services.yml
  #
  # Local app can in theory override in local UmlautController to have
  # different custom behavior for calculating the collection, but this
  # is not entirely tested yet. 
  def create_collection    
    # trim out ones with disabled:true
    services = ServiceStore.config["default"]["services"].reject {|id, hash| hash && hash["disabled"] == true}
            
    return Collection.new(@user_request, services)
  end
  
  
end
