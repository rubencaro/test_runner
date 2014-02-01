#!/usr/bin/env ruby
# encoding: utf-8
puts "\n  Running test runner!!"
require 'rubygems'
require 'eventmachine'
require 'pty'

$rails = false
$last = nil
$results = nil
$testing_now = nil
$watch_list = []

RUNNER_PATH = File.dirname(File.absolute_path(__FILE__)) # /app/test
APP_PATH = File.dirname(RUNNER_PATH) # /app

module KeyboardHandler
  include EM::Protocols::LineText2
  def receive_line data
    parse_command data
  end
end

module FileWatcher
  def file_modified
#     print '-- Modified --'
    fire_test path
  end

  def file_deleted
#     print '-- Deleted --'
    fire_test path
  end

  def unbind
    # try to rebind, some editors just delete the file and create a new one
    get_watch_list.delete path
    try_this_file path
  end

  def fire_test(file)
#     puts "File changed: #{file}..."
    test_file file
  end
end

def get_watch_list
  $watch_list
end

def try_this_file(path)
  begin
    unless $watch_list.include?(path) then
      EM.watch_file(path,FileWatcher)
      print "#{path}..."
      $watch_list << path
    end
  rescue
    $watch_list.delete path
    puts "Not watching #{path}..."
    prompt
  end
end

def refresh_file_watchers
  puts "Refreshing file list..."
  get_file_list.each do |file|
    try_this_file file
  end
end

def prompt
  print "\n\033[01;37mWatching files. Enter command: \033[00m"
end

def parse_command(opts)
  if (opts =~ /\bhelp\b/i) then
    puts "Available commands:
    'rails' or 'r' \t to toggle Rails mode.
    'refresh' or 'ref' \t to refresh watch file list.
    'show' \t to show the options' state.
    'all' or 'a' \t to run all tests now.
    'last' or 'l' \t to run last test.
    'notify' or 'n' \t to show last test results."
    prompt
  elsif (opts =~ /\bshow\b/i) then
    puts "Rails mode = #{$rails}"
    prompt
  elsif (opts =~ /\brails\b/i or opts =~ /\br\b/i) then
    if $rails then $rails = false else $rails = true end
    puts "Changed 'Rails' to #{$rails}"
    prompt
  elsif (opts =~ /\brefresh\b/i or opts =~ /\ref\b/i) then
    refresh_file_watchers
    prompt
  elsif (opts =~ /\ball\b/i or opts =~ /\ba\b/i) then
    run_all_tests
  elsif (opts =~ /\blast\b/i or opts =~ /\bl\b/i) then
    run_last_test
  elsif (opts =~ /\bnotify\b/i or opts =~ /\bn\b/i) then
    notify_last
  else
    # try it as a file name
    opts = opts + '.rb' unless opts =~ /\.rb$/
    test_file opts
  end
#   prompt
end

def run_cmd(cmd)
  res = ''
#  fhi = IO.popen(cmd)
#  while (line = fhi.gets)
#    print line
#    res += line
#  end
  begin
    PTY.spawn( "bundle exec " + cmd + " 2>&1" ) do |stdin, stdout, pid|
      begin; stdin.each { |line| print line; res += line }; rescue Errno::EIO; end
    end
  rescue PTY::ChildExited; puts "The child process exited!"; end
  res
end

def get_file_list
  file_list = `find . -name '*.rb'`.split
#   puts "\nFiles to watch... #{file_list.inspect}\n\n"
  file_list
end

def get_test_list
  `find . -name '*_test.rb'`.split
end

def test_file(file)
  return if $testing_now == file
  $testing_now = file
  puts "Testing file: #{file}..."
  refresh_file_watchers
  if file =~ /_test\.rb$/ then  #already a test file
    puts "Already a test file !"
    run_test_file(file)
  else
    # look for the test file
    filename = file.gsub('.rb','_test.rb').match(/([^\/]+\.rb)/)[1]
    test_files = get_test_list.select {|i| i =~ /\b#{filename}/ }
    if test_files.empty? then
      puts "\n  Test file not found: #{filename}\n\n"
      prompt
    else
      puts "Running these files: #{test_files.inspect}"
      test_files.each do |test_file|
        run_test_file(test_file)
      end
    end
  end
  EM.add_timer(1) do $testing_now = nil end # avoid weird double watch firing
end

def run_all_tests
  puts "\nRunning all tests..."
  if $rails then
    cmd = "rake test"
  else
    cmd = "ruby -I test test/all.rb" #get_test_list.collect { |fn| "\"#{fn}\"" }.map { |fn| "ruby -I test #{fn}"}.join('; ')
  end
  puts "Command: #{cmd}"

  res = run_cmd cmd

  notify res
  $last = cmd
end

def run_test_file(path)
  puts "Running #{path}..."
  cmd = "ruby -I test #{path}"
  puts "Command: #{cmd}"

  res = run_cmd cmd

  notify res
  $last = cmd
end

def run_last_test
  if $last.nil? then
    puts "\n  No test run yet...\n\n"
  else
    puts "Running last test..."
    puts "Command: #{$last}"
    res = run_cmd $last
    notify res
  end
end

def notify(output)
#   puts output
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
  prompt
end

def notify_last
  if $results.nil? then
    puts "\n  No results yet...\n\n"
  else
    notify_results
  end
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
  icon = '/Users/minoru/Desktop/gtk-cancel.png'
  icon = '/Users/minoru/Desktop/gtk-ok.png' if $tests_success
  icon = '/Users/minoru/Desktop/gtk-preferences.png' if $tests_partial_success

  message = "#{$results[:tests]} tests, #{$results[:assertions]} assertions, #{$results[:failures]} failures, #{$results[:errors]} errors
  #{$results[:pendings]} pendings, #{$results[:omissions]} omissions, #{$results[:notifications]} notifications"
  system("growlnotify --image #{icon} -m 'Testing results [#{$results[:secs]} secs]' '#{message}'")
end

def error(e)
  puts "#{e}\n#{e.backtrace.first}"
end

EM.error_handler{|e| error e }

EM.kqueue = true if EM.kqueue? # file watching requires kqueue on OSX

EM.run do
  EM.open_keyboard(KeyboardHandler)
  refresh_file_watchers
  prompt
end
