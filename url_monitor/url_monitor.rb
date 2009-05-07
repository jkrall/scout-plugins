require 'net/http'
require 'uri'

class UrlMonitor < ScoutAgent::Plugin
  include Net
  
  TEST_USAGE = "#{File.basename($0)} url URL last_run LAST_RUN"
  TIMEOUT_LENGTH = 50 # seconds
  
  def build_report
    if @options["url"].strip.length == 0
      return error(:subject => "A url wasn't provided.")
    end
    
    unless (@options["url"].index("http://") == 0 || @options["url"].index("https://") == 0)
      @options["url"] = "http://" + @options["url"]
    end
    
    response = http_response
    report(:status => response.class.to_s)
    
    is_up = valid_http_response?(response) ? 1 : 0
    report(:up => is_up)
    
    if is_up != memory(:was_up)
      if is_up == 0
        alert(:subject => "The URL [#{@options['url']}] is not responding",
              :body => "URL: #{@options['url']}\n\nStatus: #{response.to_s}"
              ) 
        remember(:down_at => Time.now)
      else
        if memory(:was_up) && memory(:down_at)
          alert(:subject => "The URL [#{@options['url']}] is responding again",
                :body => "URL: #{@options['url']}\n\nStatus: #{response.to_s}. " +
                          "Was unresponsive for #{(Time.now - memory(:down_at)).to_i} seconds"
                )
        else
          alert(:subject => "The URL [#{@options['url']}] is responding",
                :body => "URL: #{@options['url']}\n\nStatus: #{response.to_s}. "
               )
        end
        memory.delete(:down_at)
            
      end
    end
    
    remember(:was_up => is_up)
  rescue
    error(:subject => "Error monitoring url [#{@options['url']}]",
          :body    => $!.message + '<br\><br\>' + $!.backtrace.join('<br/>'))
  end
  
  def valid_http_response?(result)
    [HTTPOK,HTTPFound].include?(result.class) 
  end
  
  # returns the http response (string) from a url
  def http_response  
    url = @options['url']

    uri = URI.parse(url)

    response = nil
    retry_url_trailing_slash = true
    retry_url_execution_expired = true
    begin
      Net::HTTP.start(uri.host,uri.port) {|http|
            http.open_timeout = TIMEOUT_LENGTH
            req = Net::HTTP::Get.new((uri.path != '' ? uri.path : '/' ) + (uri.query ? ('?' + uri.query) : ''))
            if uri.user && uri.password
              req.basic_auth uri.user, uri.password
            end
            response = http.request(req)
      }
    rescue Exception => e
      # forgot the trailing slash...add and retry
      if e.message == "HTTP request path is empty" and retry_url_trailing_slash
        url += '/'
        uri = URI.parse(url)
        h = Net::HTTP.new(uri.host)
        retry_url_trailing_slash = false
        retry
      elsif e.message =~ /execution expired/ and retry_url_execution_expired
        retry_url_execution_expired = false
        retry
      else
        response = e.to_s
      end
    end
        
    return response
  end
  
  
end
