class DiskUsage < Scout::Plugin

  # the Disk Freespace RegEx
  DF_RE = /\A\s*(\S.*?)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*\z/

  # Parses the file systems lines according to the Regular Expression
  # DF_RE.
  # 
  # normal line ex:
  # /dev/disk0s2   233Gi   55Gi  177Gi    24%    /
  
  # multi-line ex:
  # /dev/mapper/VolGroup00-LogVol00
  #                        29G   25G  2.5G  92% /
  #
  def parse_file_systems(io, &line_handler)
    line_handler ||= lambda { |row| pp row }
    headers      =   nil

    row = ""
    io.each do |line|
      if headers.nil? and line =~ /\AFilesystem/
        headers = line.split(" ", 6)
      else
        row << line
        if row =~  DF_RE
          fields = $~.captures
          line_handler[headers ? Hash[*headers.zip(fields).flatten] : fields]
          row = ""
        end
      end
    end
  end
  
  # Ensures disk space metrics are in GB. Metrics that don't contain 'G,M,or K' are just
  # turned into integers.
  def clean_value(value)
    if value =~ /G/i
      value.to_i
    elsif value =~ /M/i
      (value.to_f/1024.to_f).round
    elsif value =~ /K/i
      (value.to_f/1024.to_f/1024.to_f).round
    else
      value.to_i
    end
  end
  
  def build_report
    df_command   = @options["command"] || "df -h"
    df_output    = `#{df_command}`
          
    df_lines = []
    parse_file_systems(df_output) { |row| df_lines << row }
    
    # if the user specified a filesystem use that
    df_line = nil
    if @options["filesystem"]
      df_lines.each do |line|
        if line.has_value?(@options["filesystem"])
          df_line = line
        end
      end
    end
    
    # else just use the first line
    df_line ||= df_lines.first
      
    # remove 'filesystem' and 'mounted on' if present - these don't change. 
    df_line.reject! { |name,value| ['filesystem','mounted on'].include?(name.downcase.gsub(/\n/,'')) }  
      
    # capacity on osx = Use% on Linux ... convert anything that isn't size, used, or avail to capacity ... a big assumption?
    assumed_capacity = df_line.find { |name,value| !['size','used','avail'].include?(name.downcase.gsub(/\n/,''))}
    df_line.delete(assumed_capacity.first)
    df_line['capacity'] = assumed_capacity.last
      
    df_line.each do |name, value|
      report(name.downcase.strip.to_sym => clean_value(value))
    end
  rescue
    { :error => { :subject => "Couldn't use `df` as expected.",
                  :body    => $!.message } }
  end
end
