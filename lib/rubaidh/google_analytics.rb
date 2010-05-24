require 'active_support'
require 'action_pack'
require 'action_view'

module Rubaidh # :nodoc:
  # This module gets mixed in to ActionController::Base
  module GoogleAnalyticsMixin
    # The javascript code to enable Google Analytics on the current page.
    # Normally you won't need to call this directly; the +add_google_analytics_code+
    # after filter will insert it for you.
    def google_analytics_code
      GoogleAnalytics.google_analytics_code(request.ssl?) if GoogleAnalytics.enabled?(request.format)
    end
    
    # An after_filter to automatically add the analytics code.
    # If you intend to use the link_to_tracked view helpers, you need to set Rubaidh::GoogleAnalytics.defer_load = false
    # to load the code at the top of the page
    # (see http://www.google.com/support/googleanalytics/bin/answer.py?answer=55527&topic=11006)
    def add_google_analytics_code
      if GoogleAnalytics.asynchronous_mode
        response.body.sub! /<[bB][oO][dD][yY]>/, "<body>#{google_analytics_code}" if response.body.respond_to?(:sub!)
      elsif GoogleAnalytics.defer_load
        response.body.sub! /<\/[bB][oO][dD][yY]>/, "#{google_analytics_code}</body>" if response.body.respond_to?(:sub!)
      else
        response.body.sub! /(<[bB][oO][dD][yY][^>]*>)/, "\\1#{google_analytics_code}" if response.body.respond_to?(:sub!)
      end
    end
  end

  class GoogleAnalyticsConfigurationError < StandardError; end

  # The core functionality to connect a Rails application
  # to a Google Analytics installation.
  class GoogleAnalytics
    
    @@custom_vars = { }
    ##
    # :singleton-method
    # Specify a custom variable to include in the analytics javascript
    # name: variable name
    # value: variable value
    # slot: variable slot (1,2,3,4, or 5)
    # scope: variable scope (page => 3, sesion => 2, visitor => 1)
    def self.set_custom_var(name, value, slot = 1, scope = 3)
      @@custom_vars[name] = { :value => value, :slot => slot, :scope => scope }
    end
    
    ##
    # :singleton-method
    # Clear all custom variables currently set
    def self.clear_all_custom_vars()
      @@custom_vars = { }
    end
    
    ##
    # :singleton-method
    # Clear the custom variable specified
    def self.clear_custom_var(name)
      @@custom_vars[name].delete
    end
    
    @@tracker_id = nil
    ##
    # :singleton-method:
    # Specify the Google Analytics ID for this web site. This can be found
    # as the value of +_getTracker+ if you are using the new (ga.js) tracking
    # code, or the value of +_uacct+ if you are using the old (urchin.js)
    # tracking code.
    cattr_accessor :tracker_id  

    @@domain_name = nil
    ##
    # :singleton-method:
    # Specify a different domain name from the default. You'll want to use
    # this if you have several subdomains that you want to combine into
    # one report. See the Google Analytics documentation for more
    # information.
    cattr_accessor :domain_name

    @@legacy_mode = false
    ##
    # :singleton-method:
    # Specify whether the legacy Google Analytics code should be used. By
    # default, the new Google Analytics code is used.
    cattr_accessor :legacy_mode

    @@asynchronous_mode = false
    ##
    # :singleton-method:
    # Specify whether the new Asynchronous Google Analytics code should be used.
    # By default, the synchronous Google Analytics code is used.
    # For more information:
    # http://code.google.com/apis/analytics/docs/tracking/asyncTracking.html
    cattr_accessor :asynchronous_mode
    
    @@analytics_url = 'http://www.google-analytics.com/urchin.js'
    ##
    # :singleton-method:
    # The URL that analytics information is sent to. This defaults to the
    # standard Google Analytics URL, and you're unlikely to need to change it.
    # This has no effect unless you're in legacy mode.
    cattr_accessor :analytics_url

    @@analytics_ssl_url = 'https://ssl.google-analytics.com/urchin.js'
    ##
    # :singleton-method:
    # The URL that analytics information is sent to when using SSL. This defaults to the
    # standard Google Analytics URL, and you're unlikely to need to change it.
    # This has no effect unless you're in legacy mode.
    cattr_accessor :analytics_ssl_url

    @@environments = ['production']
    ##
    # :singleton-method:
    # The environments in which to enable the Google Analytics code. Defaults
    # to 'production' only. Supply an array of environment names to change this.
    cattr_accessor :environments
    
    @@formats = [:html, :all]
    ##
    # :singleton-method:
    # The request formats where tracking code should be added. Defaults to +[:html, :all]+. The entry for
    # +:all+ is necessary to make Google recognize that tracking is installed on a
    # site; it is not the same as responding to all requests. Supply an array
    # of formats to change this.
    cattr_accessor :formats

    @@defer_load = true
    ##
    # :singleton-method:
    # Set this to true (the default) if you want to load the Analytics javascript at 
    # the bottom of page. Set this to false if you want to load the Analytics 
    # javascript at the top of the page. The page will render faster if you set this to
    # true, but that will break the linking functions in Rubaidh::GoogleAnalyticsViewHelper.
    cattr_accessor :defer_load
    
    @@local_javascript = false
    ##
    # :singleton-method:
    # Set this to true to use a local copy of the ga.js (or urchin.js) file.
    # This gives you the added benefit of serving the JS directly from your
    # server, which in case of a big geographical difference between your server
    # and Google's can speed things up for your visitors. Use the 
    # 'google_analytics:update' rake task to update the local JS copies.
    cattr_accessor :local_javascript
    
    ##
    # :singleton-method:
    # Set this to override the initialized domain name for a single render. Useful
    # when you're serving to multiple hosts from a single codebase. Typically you'd 
    # set up a before filter in the appropriate controller:
    #    before_filter :override_domain_name
    #    def override_domain_name
    #      Rubaidh::GoogleAnalytics.override_domain_name  = 'foo.com'
    #   end
    cattr_accessor :override_domain_name
    
    ##
    # :singleton-method:
    # Set this to override the initialized tracker ID for a single render. Useful
    # when you're serving to multiple hosts from a single codebase. Typically you'd 
    # set up a before filter in the appropriate controller:
    #    before_filter :override_tracker_id
    #    def override_tracker_id
    #      Rubaidh::GoogleAnalytics.override_tracker_id  = 'UA-123456-7'
    #   end
    cattr_accessor :override_tracker_id
    
    ##
    # :singleton-method:
    # Set this to override the automatically generated path to the page in the
    # Google Analytics reports for a single render. Typically you'd set this up on an 
    # action-by-action basis:
    #    def show
    #      Rubaidh::GoogleAnalytics.override_trackpageview = "path_to_report"
    #      ...
    cattr_accessor :override_trackpageview
    
    # Return true if the Google Analytics system is enabled and configured
    # correctly for the specified format
    def self.enabled?(format)
      raise Rubaidh::GoogleAnalyticsConfigurationError if tracker_id.blank? || analytics_url.blank?
      environments.include?(RAILS_ENV) && formats.include?(format.to_sym)
    end
    
    # Construct the javascript code to be inserted on the calling page. The +ssl+
    # parameter can be used to force the SSL version of the code in legacy mode only.
    def self.google_analytics_code(ssl = false)
      if asynchronous_mode
        code = asynchronous_google_analytics_code
      elsif legacy_mode
        code = legacy_google_analytics_code(ssl)
      else
        code = synchronous_google_analytics_code
      end
      
      return code
    end

    # Construct the legacy version of the Google Analytics code. The +ssl+
    # parameter specifies whether or not to return the SSL version of the code.
    def self.legacy_google_analytics_code(ssl = false)
      extra_code = domain_name.blank? ? nil : "_udn = \"#{domain_name}\";"
      if !override_domain_name.blank?
        extra_code = "_udn = \"#{override_domain_name}\";"
        self.override_domain_name = nil
      end

      url = legacy_analytics_js_url(ssl)

      code = <<-HTML
      <script src="#{url}" type="text/javascript">
      </script>
      <script type="text/javascript">
      _uacct = "#{request_tracker_id}";
      #{extra_code}
      urchinTracker(#{request_tracked_path});
      </script>
      HTML
    end

    # Construct the synchronous version of the Google Analytics code.
    def self.synchronous_google_analytics_code
      if !override_domain_name.blank?
        domain_code = "pageTracker._setDomainName(\"#{override_domain_name}\");"
        self.override_domain_name = nil
      elsif !domain_name.blank?
        domain_code = "pageTracker._setDomainName(\"#{domain_name}\");"
      else
        domain_code = nil
      end
      
      custom_vars = []
      @@custom_vars.each do |name, var|
        custom_vars << "pageTracker._setCustomVar(#{var[:slot]}, \"#{name}\", \"#{var[:value]}\", #{var[:scope]});"
      end
      
      if local_javascript
        code = <<-HTML
        <script src="#{LocalAssetTagHelper.new.javascript_path( 'ga.js' )}" type="text/javascript">
        </script>
        HTML
      else
        code = <<-HTML
        <script type="text/javascript">
          var gaJsHost = (("https:" == document.location.protocol) ? "https://ssl." : "http://www.");
          document.write(unescape("%3Cscript src='" + gaJsHost + "google-analytics.com/ga.js' type='text/javascript'%3E%3C/script%3E"));
        </script>
        HTML
      end
      
      code << <<-HTML
      <script type="text/javascript">
        <!--//--><![CDATA[//><!--
          try {
            var pageTracker = _gat._getTracker('#{request_tracker_id}');
            #{domain_code}
            pageTracker._initData();
            #{custom_vars.empty? ? nil : custom_vars.join("\n")}
            pageTracker._trackPageview(#{request_tracked_path});
          } catch(err) {}
        //--><!]]>
      </script>
      HTML
    end

    # Construct the new asynchronous version of the Google Analytics code.
    def self.asynchronous_google_analytics_code
      if !override_domain_name.blank?
        domain_code = "_gaq.push(['_setDomainName', '#{override_domain_name}']);"
        self.override_domain_name = nil
      elsif !domain_name.blank?
        domain_code = "_gaq.push(['_setDomainName', '#{domain_name}']);"
      else
        domain_code = nil
      end
        
      custom_vars = []
      @@custom_vars.each do |name, var|
        custom_vars << "_gaq.push(['_setCustomVar', '#{name}', '#{var[:value]}', #{var[:scope]}]);"
      end

      code = <<-HTML
      <script type="text/javascript">
        var _gaq = _gaq || [];
        _gaq.push(['_setAccount', '#{request_tracker_id}']);
        #{domain_code}
        #{custom_vars.empty? ? nil : custom_vars.join("\n")}
        _gaq.push(['_trackPageview(#{request_tracked_path})']);
        (function() {
          var ga = document.createElement('script'); ga.type = 'text/javascript'; ga.async = true;
          ga.src = ('https:' == document.location.protocol ? 'https://ssl' : 'http://www') + '.google-analytics.com/ga.js';
          (document.getElementsByTagName('head')[0] || document.getElementsByTagName('body')[0]).appendChild(ga);
        })();
      </script>
      HTML
    end
    
    # Generate the correct URL for the legacy Analytics JS file
    def self.legacy_analytics_js_url(ssl = false)
      if local_javascript
        LocalAssetTagHelper.new.javascript_path( 'urchin.js' )
      else
        ssl ? analytics_ssl_url : analytics_url
      end
    end

    # Determine the tracker ID for this request
    def self.request_tracker_id
      use_tracker_id = override_tracker_id.blank? ? tracker_id : override_tracker_id
      self.override_tracker_id = nil
      use_tracker_id
    end
    
    # Determine the path to report for this request
    def self.request_tracked_path
      use_tracked_path = override_trackpageview.blank? ? '' : "'#{override_trackpageview}'"
      self.override_trackpageview = nil
      use_tracked_path
    end
    
  end

  class LocalAssetTagHelper # :nodoc:
    # For helping with local javascripts
    include ActionView::Helpers::AssetTagHelper
  end
end
