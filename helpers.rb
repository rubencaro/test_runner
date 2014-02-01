# encoding: utf-8
BASE_PATH = File.dirname(File.absolute_path(__FILE__ + '/..')) unless defined? BASE_PATH
require BASE_PATH + '/app/constants.rb'

require 'yaml'
require 'mysql2'
require 'timeout'
require 'eventmachine'
require 'em-synchrony'
require 'em-synchrony/mysql2'
require 'securerandom'
require 'net/http'
require 'net/ssh/gateway'
require 'connection_pool'

require 'log_helpers'
require 'mail_helpers'

# Time Helpers
# nanoseconds since 1970-1-1
def get_timestamp
  t = Time.now
  t.to_i * 1000000000 + t.nsec
end

# from ts nanoseconds since 1970-1-1
def get_time(ts)
  Time.at((ts.to_i/1e9).to_i)
end

def http_get_request(url)
  begin
    uri = URI.parse(url)
    http = ::Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = ::Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)
  rescue Exception => ex
    log_ex ex, true, "Request: #{url}"
    return { :valid => false, :error_msg => ex.message, :request => url }
  end

  status = response.code
  return { :valid => true, :request => url, :response => response.body, :status => status }
end

def get_formatted_tag(tag)
  "#{tag[0,4]}-#{tag[4,2]}-#{tag[6,2]} #{tag[8,2]}:#{tag[10,2]}:#{tag[12,2]}"
end

# DB Helpers
def to_db_format(object)
  case object.class.to_s
  when 'String'
    quote(object)
  when 'Time'
    "FROM_UNIXTIME(#{object.to_i})"
  when 'Date'
    "FROM_UNIXTIME(#{object.to_time.to_i})"
  when 'NilClass'
    'NULL'
  else
    object
  end
end

def query(sql_client, sql, options = {})
  ping_retries = 0
  res = []
  if sql_client.class == MySQLPool then
    sql_client.with {|conn| res = do_query(conn, sql, options) }
  else
    res = do_query(sql_client, sql, options)
  end
  res
end

def do_query(conn, sql, options = {})
  res = []
  begin
    res = conn.query(sql, options)
  rescue Mysql2::Error => ex
    if ex.to_s =~ /has gone away/ or ex.to_s =~ /Lost connection/  or ex.to_s =~ /Timeout/
      ping_retries += 1
      conn.ping
      retry if ping_retries < MAX_MYSQL_PING_RETRIES
    end
    raise ex, "SQL: #{sql}\nException: #{ex}"
  end
  res
end

def get_db_conf(db_config_name, config_path = nil)
  config_path = File.expand_path "#{BASE_PATH}/config/database.yml" if config_path.nil?
  YAML.load_file(config_path)[db_config_name]
end

def get_db(db_name, db_conf = nil)
  db_conf = get_db_conf(db_name) if not db_conf
  Mysql2::Client.new(:host => db_conf['host'],
                     :username => db_conf['username'],
                     :password => db_conf['password'],
                     :socket => db_conf['socket'],
                     :database => db_conf['database'],
                     :reconnect => true)
end

def get_threaded_pool(opts = {})
  opts[:db_conf] ||= get_db_conf(opts[:db_name])
  opts[:size] = opts[:size] || opts[:db_conf]['pool'] || 5
  opts[:timeout] ||= 30
  MySQLPool.new(:size => opts[:size], :timeout => opts[:timeout]){ get_db opts[:db_name], opts[:db_conf] }
end

# yields connection through tunnel, then destroys the tunnel
#
#  opts = {
#    database: 'devops',
#    username: 'epdp',
#    password: 'pass',
#    host: '192.168.157.23',
#    port: 3306,
#    ssh_user: 'epdp',
#    ssh_host: 'fowler'
#  }
#
def get_db_through_tunnel(opts)
  opts['port'] ||= 3306
  gateway = Net::SSH::Gateway.new(opts['ssh_host'],opts['ssh_user'])
  begin
    port = rand(50000)+1024 # random port
    gateway.open(opts['host'],opts['port'],port)
  rescue Errno::EADDRINUSE
    retry
  end
  puts "Tunnelling #{opts['host']}:#{opts['port']} from #{opts['ssh_host']} through 127.0.0.1:#{port}"
  db = Mysql2::Client.new(:host => '127.0.0.1',
                          :username => opts['username'],
                          :password => opts['password'],
                          :database => opts['database'],
                          :port => port)
  yield db
ensure
  db.query 'commit' rescue nil
  db.close rescue nil
  gateway.shutdown!
end

def get_db_async(db_name)
  db_conf = get_db_conf(db_name)
  EM::Synchrony::ConnectionPool.new(:size => 5) do
      ::Mysql2::EM::Client.new(:host => db_conf['host'],
                               :username => db_conf['username'],
                               :password => db_conf['password'],
                               :socket => db_conf['socket'],
                               :database => db_conf['database'],
                               :reconnect => true)
  end
end

# Action Helpers
def generate_permalink(length = 4)
  SecureRandom.hex(length)
end

def syscall(cmd)
  `#{cmd}`.force_encoding('utf-8').scrub
end

def timeout(secs, msg = nil, &block)
  Timeout::timeout(secs, &block)
rescue Timeout::Error
  raise Timeout::Error, "Timeout, waited #{secs}secs. #{msg.to_s}"
end

def em_system(cmd)
  res = nil
  f = Fiber.current
  EM.system('sh', '-c', "#{cmd} 2>&1") do |output, status|
    res = output.force_encoding('utf-8').scrub
    f.resume
  end
  Fiber.yield
  res
end

def em_timeout(secs, msg = nil, &block)
  in_fibers [1], :timeout_secs => secs, :msg => msg.to_s, &block
end

def em_sleep(secs)
  em_system "sleep #{secs.to_f}" # sleep without timers
end

def in_fibers(array, opts={}, &block)
  timeout_secs = opts[:timeout_secs] || 30
  expires = Time.now + timeout_secs

  fibers = []
  array.each do |i|
    fibers << Fiber.new do
      block.call i
    end
  end
  fibers.each{|f| f.resume}

  while fibers.any?{|f| f.alive?}
    raise "EM Reactor stopped" if not EM.reactor_running?
    raise(Timeout::Error, "Timeout in_fibers, waited #{timeout_secs}secs. #{opts[:msg].to_s}") if timeout_secs > 0 and Time.now > expires
    em_sleep 1
  end
end

def in_threads(array, opts={}, &block)
  timeout_secs = opts[:timeout_secs] || 30
  expires = Time.now + timeout_secs

  master = Thread.current

  threads = []
  array.each do |i|
    threads << Thread.new do
      begin
        block.call i
      rescue => ex
        master.raise ex
      end
    end
  end

  while threads.any?{|t| t.alive?}
    raise(Timeout::Error, "Timeout in_threads, waited #{timeout_secs}secs. #{opts[:msg].to_s}") if timeout_secs > 0 and Time.now > expires
    sleep 1
  end
ensure
  threads.each{|t| t.kill}
end

# 'watcher' must respond to 'file_modified'
def watch_file(path,watcher)
  @watched_files ||= {}
  @watched_files[path] ||= {}
  @watched_files[path][:watchers] ||= []
  @watched_files[path][:watchers] << watcher
  @watched_files[path][:mtime] = File.new(path).mtime
end

def check_watched_files
  @watched_files.each do |path,data|
    file = File.new(path)
    next if data[:mtime] == file.mtime
    data[:watchers].each{ |w| w.file_modified file }
    data[:mtime] = file.mtime # maybe we want to rerun this
  end
end


def quote(str)
  "'#{str.to_s.gsub(/\\/, '\&\&').gsub(/'/, "''")}'"
end

def replace_vars(string = '',vars = {})
  res = string.to_s.clone
  vars.each do |k,v|
    res.gsub! /@@#{k.to_s}/,v
  end
  res
end

# Render helpers
def not_found
  [404, {"Content-Type" => "text/html"}.merge(ajax_headers), ["404 Not Found"]]
end

def simple_ok
  [200, {"Content-Type" => "text/html"}.merge(ajax_headers), ['200 OK']]
end

def ajax_headers
  {
    "Access-Control-Allow-Origin" => '*',
    "Access-Control-Request-Method" => '*',
    "Access-Control-Allow-Methods" => '*'
  }
end

# file path inside app/views/, layout inside app/views/layouts/
def render_view(file,layout = nil, locals = nil)
  title = ''
  javascripts = []
  styles = []
  head = ''
  content = Erubis::Eruby.new(File.read(BASE_PATH + '/app/views/' + file)).result(binding)
  if layout.nil? then
    html = content
  else
    html = Erubis::Eruby.new(File.read(BASE_PATH + '/app/views/layouts/' + layout)).result(binding)
  end
  [200, {"Content-Type" => "text/html"}.merge(ajax_headers), html ]
end

# file path inside app/views/
def render_partial(file, locals = {})
  Erubis::Eruby.new(File.read(BASE_PATH + '/app/views/' + file)).evaluate(locals)
end

def render_loadable(locals = {})
  render_partial('linode/_loadable.erubis',locals)
end

def render_json(res, to_json = true, headers = {})
  if to_json then
    res = res.to_json
  end
  [200, {"Content-Type" => "application/json"}.merge(ajax_headers).merge(headers), res]
end

# options = ['label' => 'value','label' => 'value']
def select_tag(args)
  html = "<select"
  html << " id=\"#{args[:id].to_s}\"" if args[:id]
  html << " name=\"#{args[:name].to_s}\"" if args[:name]
  html << " class=\"#{args[:class].to_s}\"" if args[:class]
  html << " style=\"#{args[:style].to_s}\"" if args[:style]
  html << ">"
  args[:options].each do |label,value|
    html << "<option value=\"#{value.to_s}\""
    html << " selected=\"selected\"" if args[:value_selected] and value == args[:value_selected]
    html << ">#{label.to_s}</option>"
  end
  html << "</select>"
end

def check_args(passed, required, hash_response = false)
  passed_required_args = required & passed.keys
  if passed_required_args != required then
    msg = "Missing arguments: #{required - passed_required_args}"
    if hash_response then
      return { :valid => false, :msg => msg }
    end
    raise ArgumentError.new msg
  end
  if hash_response then
    return { :valid => true }
  end
  true
end

# Adaptar ConnectionPool para MySQL
# https://github.com/mperham/connection_pool/blob/master/lib/connection_pool.rb
#
class MySQLPool < ConnectionPool::Wrapper
  def query(sql, options)
    with do |conn|
      conn.query sql, options
    end
  end
end

# Mundo monkeypatch!
# código de ActiveSupport 3.0.9 para Hash.to_param, Array.to_query y Object.to_query
class Object
  def to_db(opts = {})
    to_s.force_encoding('utf-8')
  end

  def to_query(namespace=nil)
    case self.class.to_s
    when 'Hash'
      self.collect do |key, value| value.to_query(namespace ? "#{namespace}[#{key}]" : key) end.sort * '&'
    when 'Array'
      prefix = "#{namespace}[]"
      self.collect do |value| value.to_query(prefix) end.join '&'
    else
      require 'cgi' unless defined?(CGI) && defined?(CGI::escape)
      "#{CGI.escape(namespace.to_s).gsub(/%(5B|5D)/n) { [$1].pack('H*') }}=#{CGI.escape(self.to_s)}"
    end
  end
end

class String
  BINARY_STRING_DIFF_LIMIT = 3072
  def to_db(opts = {})
    output = nil

    if size > BINARY_STRING_DIFF_LIMIT
      output = "x'#{bytes.map { |byte| "%02x" % byte }.join}'"
    else
      if opts[:db_quote]
        output = "#{opts[:db_quote].escape(self)}"
      else
        output = quote(self)
      end
    end

    output.force_encoding('utf-8')
  end

  def constantize
    names = self.split('::')
    names.shift if names.empty? || names.first.empty?

    constant = Object
    names.each do |name|
      constant = constant.const_defined?(name) ? constant.const_get(name) : constant.const_missing(name)
    end
    constant
  end

  # only get AsdfGfre from asdf_gfre
  def camelize
    self.split('_').map {|w| w.capitalize}.join
  end

  # simplified version of rails', only get asdf_gfre from AsdfGfre
  def underscore
    self.gsub(/(\w+)([A-Z\d]+)/,'\1_\2').downcase
  end

  def classify
    self.camelize
  end
end

class Hash
  # format keys and values to be db fields and db values respectively
  def format
    res = {}
    self.each do |k,v|
      res["`#{k.to_s}`"] = v.to_db
    end
    res
  end

  # gets an array of strings ready to be injected on sql with a join operation
  # Ex:
  # { :a => 3, :b => 'asdfsr' }
  # ---->   [ "`a` = 3", "`b` = 'asdfsr'" ]
  def get_db_array
    res = []
    self.format.each{ |k,v| res << "#{k} = #{v}" }
    res
  end

  def to_openstruct
    require 'ostruct'
    OpenStruct.new(self)
  end

  def stringify_keys!
    self.keys.each do |key|
      self[key.to_s] = self.delete(key)
    end
    self
  end
end

## no es monkey patching !!
## from: http://snippets.aktagon.com/snippets/453-Ruby-struct-to-hash-hash-to-struct-conversion
class Struct
  def to_hash
    Hash[*members.zip(values).flatten]
  end
end

class NilClass
  def to_db(opts = {})
    "NULL"
  end
end

class Date
  def to_db(opts = {})
    "'#{strftime("%F")}'"
  end
end

class Time
  def to_db(opts = {})
    "'#{strftime("%F %T")}'"
  end
end

class DateTime
  def to_db(opts = {})
    "'#{strftime("%F %T")}'"
  end
end
