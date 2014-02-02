#!/usr/bin/env ruby

APP_PATH = File.dirname(File.absolute_path(__FILE__))

require 'pty'
require 'thread'

class Ranner

  def initialize
    initialize_watched_files
    start_file_watcher
  end

  def run_cmd(cmd)
    res = ''
    begin
      PTY.spawn( "bundle exec " + cmd + " 2>&1" ) do |stdin, stdout, pid|
        begin; stdin.each { |line| print line; res += line }; rescue Errno::EIO; end
      end
    rescue PTY::ChildExited; puts "The child process exited!"; end
    res
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

  def start_file_watcher
    Thread.new do
      loop do
        check_watched_files
        sleep 0.5
      end
    end
  end

  def initialize_watched_files
    m = Module.new do
      def self.file_modified(file)
        "File modified #{File.basename file}"
        test_file file.path
      end
    end

    get_file_list.each{ |f| watch_file f, m }
  end

  def get_file_list
    `find . -name '*.rb'`.split
  end

  def get_test_list
    `find . -name '*_test.rb'`.split
  end

  def test_file(file)
    puts "Testing file: #{file}..."
    if file =~ /_test\.rb$/ then  #already a test file
      puts "Already a test file !"
      run_test_file(file)
    else
      # look for the test file
      filename = file.gsub('.rb','_test.rb').match(/([^\/]+\.rb)/)[1]
      test_files = get_test_list.select {|i| i =~ /\b#{filename}/ }
      if test_files.empty? then
        puts "\n  Test file not found: #{filename}\n\n"
      else
        puts "Running these files: #{test_files.inspect}"
        test_files.each do |test_file|
          run_test_file(test_file)
        end
      end
    end
  end

  def run_test_file(path)
    puts "Running #{path}..."
    cmd = "ruby -I test #{path}"
    puts "Command: #{cmd}"

    res = run_cmd cmd

    notify res
    $last = cmd
  end

  def notify(output)
    lines = output.split(/\n/)

    # get time spent
    finish = lines.grep /Finished tests in/
    secs=0
    finish.each do |line|
      secs += line.gsub(/Finished tests in (.+)s, /,'\1').to_f
    end

    # get @results
    result_lines = lines.grep /\d+ assertions, \d+ failures/
    $results = {:tests =>0, :assertions =>0, :failures =>0, :errors =>0, :pendings =>0, :omissions =>0, :notifications =>0}
    result_lines.each do |line|
      nums=line.gsub(/\D+/,',').split(',')
      $results[:tests]+=nums[0].to_i
      $results[:assertions]+=nums[1].to_i
      $results[:failures]+=nums[2].to_i
      $results[:errors]+=nums[3].to_i
      $results[:pendings]+=nums[4].to_i
      $results[:omissions]+=nums[5].to_i
      $results[:notifications]+=nums[6].to_i
    end

    $tests_success = true
    $tests_success = false if $results.all? do |k,v| v == 0 end
    $tests_success = ($results[:errors]==0 and $results[:failures]==0) if $tests_success # solo lo cambiamos si es true

    $tests_partial_success = ( $tests_success and $results[:pendings]!=0 )

    $results[:secs] = secs # carry exec. time to notify

    notify_results
  end

  def notify_results
    case RUBY_PLATFORM
    when /mswin|mingw|cygwin/
      # beware of this platform !!
    when /darwin/
      # growl?
      notify_by_notify_send_mac
    else
      notify_by_notify_send
    end
    # show on terminal
    if $tests_partial_success then
      print "\n \033[01;33m Partial success !! \033[0m"
    elsif $tests_success then
      print "\n \033[01;32m Success !! \033[0m"
    else
      print "\n \033[01;31m Error !! \033[0m"
    end
    puts "[#{Time.now.strftime('%T')}] #{$results.inspect}"
  end

  def notify_by_notify_send
    icon = 'gtk-cancel'
    icon = 'gtk-ok' if $tests_success
    icon = 'gtk-preferences' if $tests_partial_success
    message = "#{$results[:tests]} tests, #{$results[:assertions]} assertions, #{$results[:failures]} failures, #{$results[:errors]} errors
    #{$results[:pendings]} pendings, #{$results[:omissions]} omissions, #{$results[:notifications]} notifications"
    system("notify-send --hint int:transient:1 -i #{icon} 'Testing results [#{Time.now.strftime('%T')}]' '#{message}'")
  end

  def notify_by_notify_send_mac
    icon = './gtk-cancel.png'
    icon = './gtk-ok.png' if $tests_success
    icon = './gtk-preferences.png' if $tests_partial_success
    message = "#{$results[:tests]} tests, #{$results[:assertions]} assertions, #{$results[:failures]} failures, #{$results[:errors]} errors
    #{$results[:pendings]} pendings, #{$results[:omissions]} omissions, #{$results[:notifications]} notifications"
    system("growlnotify --image #{icon} -m 'Testing results [#{$results[:secs]} secs]' '#{message}'")
  end
end

@ranner = Ranner.new

require 'pry'

Pry.config.should_load_rc = false
Pry.config.history.should_save = false
Pry.config.history.should_load = false
Pry.config.prompt_name = 'ranner'

binding.pry
