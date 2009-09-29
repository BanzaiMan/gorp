# The following is under the "I ain't too proud" school of programming.
# global variables, repetition, and brute force abounds.
#
# You have been warned.

require 'fileutils'
require 'open3'
require 'net/http'
require 'builder'
require 'stringio'

require 'rbconfig'
$ruby = File.join(Config::CONFIG["bindir"], Config::CONFIG["RUBY_INSTALL_NAME"])

# Micro DSL for declaring an ordered set of book sections
$sections = []
def section number, title, &steps
  number = (sprintf "%f", number).sub(/0+$/,'') if number.kind_of? Float
  $sections << [number, title, steps]
end

# verify that port is available for testing
if (Net::HTTP.get_response('localhost','/',3000).code == '200' rescue false)
  STDERR.puts 'local server already running on port 3000'
  exit
end

$BASE=File.expand_path(File.dirname(caller.last.split(':').first)) unless $BASE
$WORK = File.join($BASE,'work')
$DATA = File.join($BASE,'data')
$CODE = File.join($DATA,'code')
$x = Builder::XmlMarkup.new(:indent => 2)
$toc = Builder::XmlMarkup.new(:indent => 2)
$style = Builder::XmlMarkup.new(:indent => 2)

FileUtils.mkdir_p $WORK

class String
  def unindent(n)
    gsub Regexp.new("^#{' '*n}"), ''
  end
end

def read name
  open(File.join($DATA, name)) {|file| file.read}
end

def overview message
  $x.p message.gsub(/(^|\n)\s+/, ' ').strip, :class=>'overview'
end

def desc message
  $x.p message, :class=>'desc'
end

def log type, message
  type = type.to_s.ljust(5).upcase
  STDOUT.puts Time.now.strftime("[%Y-%m-%d %H:%M:%S] #{type} #{message}")
end

def head number, title
  text = "#{number} #{title}"
  log '====>', text

  $x.a(:class => 'toc', :name => "section-#{number}") {$x.h2 text}
  $toc.li {$toc.a text, :href => "#section-#{number}"}
end

def db statement, hilight=[]
  log :db, statement
  $x.pre "sqlite3> #{statement}", :class=>'stdin'
  cmd = "sqlite3 --line db/development.sqlite3 #{statement.inspect}"
  popen3 cmd, hilight
end

def ruby args
  cmd "ruby #{args}"
end

def console script
  cmd "echo #{script.inspect} | ruby script/console '--irb=irb -f'"
end

def cmd args, hilight=[]
  log :cmd, args
  $x.pre args, :class=>'stdin'
  if args == 'rake db:migrate'
    Dir.chdir 'db/migrate' do
      date = '20080601000000'
      Dir['[0-9]*'].sort_by {|file| file=~/2008/?file:'x'+file}.each do |file|
        file =~ /^([0-9]*)_(.*)$/
        FileUtils.mv file, "#{date}_#{$2}" unless $1 == date.next!
        $x.pre "mv #{file} #{date}_#{$2}"  unless $1 == date
      end
    end
  end
  popen3 args, hilight
end

def popen3 args, hilight=[]
  Open3.popen3(args) do |pin, pout, perr|
    terr = Thread.new do
      $x.pre perr.readline.chomp, :class=>'stderr' until perr.eof?
    end
    pin.close
    until pout.eof?
      line = pout.readline
      if hilight.any? {|pattern| line.include? pattern}
        outclass='hilight'
      elsif line =~ /\x1b\[\d/
        line.gsub! /\x1b\[1m\x1b\[3\dm(.*?)\x1b\[0m/, '\1'
        outclass = 'logger'
      else
        outclass='stdout'
      end

      if line.strip.size == 0
        $x.pre ' ', :class=>outclass
      else
        $x.pre line.chomp, :class=>outclass
      end
    end
    terr.join
  end
end

def irb file
  $x.pre "irb #{file}", :class=>'stdin'
  log :irb, file
  cmd = "irb -f -rubygems -r ./config/boot --prompt-mode simple #{$CODE}/#{file}"
  Open3.popen3(cmd) do |pin, pout, perr|
    terr = Thread.new do
      $x.pre perr.readline.chomp, :class=>'stderr' until perr.eof?
    end
    pin.close
    prompt = nil
    until pout.eof?
      line = pout.readline
      if line =~ /^([?>]>)\s*#\s*(START|END):/
        prompt = $1
      elsif line =~ /^([?>]>)\s+$/
        $x.pre ' ', :class=>'irb'
        prompt ||= $1
      elsif line =~ /^([?>]>)(.*)\n/
        prompt ||= $1
        $x.pre prompt + $2, :class=>'irb'
	prompt = nil
      elsif line =~ /^\w+(::\w+)*: /
        $x.pre line.chomp, :class=>'stderr'
      elsif line =~ /^\s+from [\/.:].*:\d+:in `\w.*'\s*$/
        $x.pre line.chomp, :class=>'stderr'
      elsif line =~ /\x1b\[\d/
        line.gsub! /\x1b\[4(;\d+)*m(.*?)\x1b\[0m/, '\2'
        line.gsub! /\x1b\[0(;\d+)*m(.*?)\x1b\[0m/, '\2'
        $x.pre line.chomp, :class=>'logger'
      else
        $x.pre line.chomp, :class=>'stdout'
      end
    end
    terr.join
  end
end

def edit filename, tag=nil
  log :edit, filename
  $x.pre "edit #{filename}", :class=>'stdin'

  stale = File.mtime(filename) rescue Time.now-2
  data = open(filename) {|file| file.read} rescue ''
  before = data.split("\n")

  begin
    yield data
    open(filename,'w') {|file| file.write data}
    File.utime(stale+2, stale+2, filename) if File.mtime(filename) <= stale

  rescue Exception => e
    $x.pre :class => 'traceback' do
      STDERR.puts e.inspect
      $x.text! "#{e.inspect}\n"
      e.backtrace.each {|line| $x.text! "  #{line}\n"}
    end
    tag = nil

  ensure
    include = tag.nil?
    hilight = false
    data.split("\n").each do |line|
      if line =~ /START:(\w+)/
        include = true if $1 == tag
      elsif line =~ /END:(\w+)/
        include = false if $1 == tag
      elsif line =~ /START_HIGHLIGHT/
        hilight = true
      elsif line =~ /END_HIGHLIGHT/
        hilight = false
      elsif include
        if hilight or ! before.include?(line)
          outclass='hilight'
        else
          outclass='stdout'
        end

        if line.empty?
          $x.pre ' ', :class=>outclass
        else
          $x.pre line, :class=>outclass
        end
      end
    end
  end
end

# pluggable XML parser support
begin
  raise LoadError if ARGV.include? 'rexml'
  require 'nokogiri'
  def xhtmlparse(text)
    Nokogiri::HTML(text)
  end
  Comment=Nokogiri::XML::Comment
rescue LoadError
  require 'rexml/document'

  HTML_VOIDS = %w(area base br col command embed hr img input keygen link meta
                  param source)

  def xhtmlparse(text)
    begin
      require 'htmlentities'
      text.gsub! '&amp;', '&amp;amp;'
      text.gsub! '&lt;', '&amp;lt;'
      text.gsub! '&gt;', '&amp;gt;'
      text.gsub! '&apos;', '&amp;apos;'
      text.gsub! '&quot;', '&amp;quot;'
      text.force_encoding('utf-8') if text.respond_to? :force_encoding
      text = HTMLEntities.new.decode(text)
    rescue LoadError
    end
    doc = REXML::Document.new(text)
    doc.get_elements('//*[not(* or text())]').each do |e|
      e.text='' unless HTML_VOIDS.include? e.name
    end
    doc
  end

  class REXML::Element
    def has_attribute? name
      self.attributes.has_key? name
    end

    def at xpath
      self.elements[xpath]
    end

    def search xpath
      self.elements.to_a(xpath)
    end

    def content=(string)
      self.text=string
    end

    def [](index)
      if index.instance_of? String
        self.attributes[index]
      else
        super(index)
      end
    end

    def []=(index, value)
      if index.instance_of? String
        self.attributes[index] = value
      else
        super(index, value)
      end
    end
  end

  module REXML::Node
    def before(node)
      self.parent.insert_before(self, node)
    end

    def add_previous_sibling(node)
      self.parent.insert_before(self, node)
    end

    def serialize
      self.to_s
    end
  end

  # monkey patch for Ruby 1.8.6
  doc = REXML::Document.new '<doc xmlns="ns"><item name="foo"/></doc>'
  if not doc.root.elements["item[@name='foo']"]
    class REXML::Element
      def attribute( name, namespace=nil )
        prefix = nil
        prefix = namespaces.index(namespace) if namespace
        prefix = nil if prefix == 'xmlns'
        attributes.get_attribute( "#{prefix ? prefix + ':' : ''}#{name}" )
      end
    end
  end

  Comment = REXML::Comment
end

def snap response, form={}
  if response.content_type == 'text/plain' or response.content_type =~ /xml/
    $x.div :class => 'body' do
      response.body.split("\n").each do |line| 
        $x.pre line.chomp, :class=>'stdout'
      end
    end
    return
  end

  if response.body =~ /<body/
    body = response.body
  else
    body = "<body>#{response.body}</body>"
  end

  begin
    doc = xhtmlparse(body)
  rescue
    body.split("\n").each {|line| $x.pre line.chomp, :class=>'hilight'}
    raise
  end

  title = doc.at('html/head/title').text rescue ''
  body = doc.at('//body')
  doc.search('//link[@rel="stylesheet"]').each do |sheet|
    body.children.first.add_previous_sibling(sheet)
  end

  if ! form.empty?
    body.search('//input[@name]').each do |input|
      input['value'] ||= form[input['name']].to_s
    end
    body.search('//textarea[@name]').each do |textarea|
      textarea.text ||= form[textarea['name']].to_s
    end
  end

  %w{ a[@href] form[@action] }.each do |xpath|
    name = xpath[/@(\w+)/,1]
    body.search("//#{xpath}").each do |element|
      next if element[name] =~ /^http:\/\//
      element[name] = URI.join('http://localhost:3000/', element[name]).to_s
    end
  end

  %w{ img[@src] }.each do |xpath|
    name = xpath[/@(\w+)/,1]
    body.search("//#{xpath}").each do |element|
      if element[name][0] == ?/
        element[name] = 'data' + element[name]
      end
    end
  end

  body.search('//textarea').each do |element|
    element.content=''
  end

  attrs = {:class => 'body', :title => title}
  attrs[:class] = 'traceback' if response.code == '500'
  attrs[:id] = body['id'] if body['id']
  $x.div(attrs) do
    body.children.each do |child|
      $x << child.serialize unless child.instance_of?(Comment)
    end
  end
  $x.div :style => "clear: both"
end

def get path
  post path, {}
end

def post path, form
  $x.pre "get #{path}", :class=>'stdin'

  if path.include? ':'
    host, port, path = URI.parse(path).select(:host, :port, :path)
  else
    host, port = '127.0.0.1', 3000
  end

  Net::HTTP.start(host, port) do |http|
    get = Net::HTTP::Get.new(path)
    get['Cookie'] = $COOKIE if $COOKIE
    response = http.request(get)
    snap response, form
    $COOKIE = response.response['set-cookie'] if response.response['set-cookie']

    if ! form.empty?
      body = xhtmlparse(response.body).at('//body')
      body = xhtmlparse(response.body).root unless body
      xform = body.at('//form[.//input[@name="commit"]]')
      return unless xform
      path = xform.attribute('action').to_s unless
        xform.attribute('action').to_s.empty?
      $x.pre "post #{path}", :class=>'stdin'

      $x.ul do
        form.each do |name, value|
          $x.li "#{name} => #{value}"
        end
      end

      body.search('//input[@type="hidden"]').each do |element|
        form[element['name']] ||= element['value']
      end

      post = Net::HTTP::Post.new(path)
      post.form_data = form
      post['Cookie'] = $COOKIE
      response=http.request(post)
      snap response
    end

    if response.code == '302'
      path = response['Location']
      $x.pre "get #{path}", :class=>'stdin'
      get = Net::HTTP::Get.new(path)
      get['Cookie'] = $COOKIE if $COOKIE
      response = http.request(get)
      snap response
    end
  end
end

# select a version of Rails
if ARGV.first =~ /^_\d[.\d]*_$/
  $rails = "rails #{ARGV.first}"
elsif File.directory?(ARGV.first.to_s)
  $rails = ARGV.first
  $rails = File.join($rails,'rails') if
    File.directory?(File.join($rails,'rails'))
  $rails = File.expand_path($rails)
else
  $rails = 'rails'
end

def which_rails rails
  railties = File.join(rails, 'railties', 'bin', 'rails')
  rails = railties if File.exists?(railties)
  if File.exists?(rails)
    firstline = open(rails) {|file| file.readlines.first}
    rails = 'ruby ' + rails unless firstline =~ /^#!/
  end
  rails
end

def rails name, app=nil
  Dir.chdir($WORK)
  FileUtils.rm_rf name
  log :rails, name

  # determine how to invoke rails
  rails = which_rails $rails

  $x.pre "#{rails} #{name}", :class=>'stdin'
  popen3 "#{rails} #{name}"

  # make paths seem Mac OSX'ish
  Dir["#{name}/public/dispatch.*"].each do |dispatch|
    code = open(dispatch) {|file| file.read}
    code.sub! /^#!.*/, '#!/opt/local/bin/ruby'
    open(dispatch,'w') {|file| file.write code}
  end

  Dir.chdir(name)
  FileUtils.rm_rf 'public/.htaccess'

  cmd 'rake rails:freeze:edge' if ARGV.include? 'edge'

  if $rails != 'rails' and File.directory?($rails)
    cmd "ln -s #{$rails} vendor/rails"
  end
end

def restart_server
  log :server, 'restart'
  if $server
    $x.h3 'Restart the server.'
    Process.kill "INT", $server
    Process.wait($server)
  else
    $x.h3 'Start the server.'
  end

  $server = fork
  if $server
    # wait for server to start
    60.times do
      sleep 0.5
      begin
        status = Net::HTTP.get_response('localhost','/',3000).code
        break if %(200 404).include? status
      rescue Errno::ECONNREFUSED
      end
    end
  else
    begin
      if File.exist?('config.ru')
        require 'rack'
        server = Rack::Builder.new {eval open('config.ru').read}
        Rack::Handler::WEBrick.run(server, :Port => 3000)
      else
        # start server, redirecting stdout to a string
        $stdout = StringIO.open('','w')
        require './config/boot'
        if Rails::VERSION::MAJOR == 2
          require 'commands/server'
        else
          require 'rails/commands/server'
        end
      end
    rescue 
      STDERR.puts $!
      $!.backtrace.each {|method| STDERR.puts "\tfrom " + method}
    ensure
      Process.exit!
    end
  end
end

def secsplit section
  section.to_s.split('.').map {|n| n.to_i}
end

at_exit do
  $x.html :xmlns => 'http://www.w3.org/1999/xhtml' do
    $x.header do
      $x.title $title
      $x.meta 'http-equiv'=>'text/html; charset=UTF-8'
      $x.style :type => "text/css" do
        $x.text! <<-'EOF'.unindent(2)
          body {background-color: #F5F5DC}
          pre {font-weight: bold; margin: 0; padding: 0}
          pre.stdin {color: #800080; margin-top: 1em; padding: 0}
          pre.irb {color: #800080; padding: 0}
          pre.stdout {color: #000; padding: 0}
          pre.logger {color: #088; padding: 0}
          pre.hilight {color: #000; background-color: #FF0; padding: 0}
          pre.stderr {color: #F00; padding: 0}
          div.body {border-style: solid; border-color: #800080; padding: 0.5em}
          .traceback {background:#FDD; border: 4px solid #F00; 
                      font-weight: bold; margin-top: 1em; padding: 0.5em}
          ul.toc {list-style: none}
          ul a {text-decoration: none}
          ul a:hover {text-decoration: underline; color: #000;
                      background-color: #F5F5DC}
          ul a:visited {color: #000}
	  h2 {clear: both}
          p.desc {font-style: italic}
          p.overview {border-width: 2px; border-color: #000;
            border-style: solid; border-radius: 4em;
            background-color: #CCF; margin: 1.5em 1.5em; padding: 1em 2em; 
            -webkit-border-radius: 4em; -moz-border-radius: 4em;}
        EOF
      end
    end
  
    $x.body do
      $x.h1 $title
      $x.h2 'Table of Contents'
      $x.ul :class => 'toc'
  
      $x.h2 'Development Log'
      cmd which_rails($rails) + ' -v'
  
      cmd "#{$ruby} -v"
      cmd 'gem -v'
    
      e = nil
  
      # determine which range(s) of steps are to be executed
      ranges = ARGV.grep(/^ \d+(.\d+)? ( (-|\.\.) \d+(.\d+)? )? /x).map do |arg|
        bounds = arg.split(/-|\.\./)
        Range.new(secsplit(bounds.first), secsplit(bounds.last))
      end
      ARGV.push 'partial' unless ranges.empty?
  
      # optionally save a snapshot
      if ARGV.include? 'restore'
        log :snap, 'restore'
        Dir.chdir $BASE
        FileUtils.rm_rf "work"
        FileUtils.cp_r "snapshot", "work", :preserve => true
        Dir.chdir $WORK
        if $autorestart and File.directory? $autorestart
          Dir.chdir $autorestart
          restart_server
        end
      end
  
      # run steps
      begin
        $sections.each do |section, title, steps|
	  next if !ranges.empty? and 
                  !ranges.any? do |range| 
                    # was (in Ruby 1.8): range.include?(secsplit(section))
                    ss = secsplit(section)
                    (range.first <=> ss) <= 0 and (range.last <=> ss) >= 0
                  end
	  head section, title
	  steps.call
        end
      rescue Exception => e
        $x.pre :class => 'traceback' do
	  STDERR.puts e.inspect
	  $x.text! "#{e.inspect}\n"
	  e.backtrace.each {|line| $x.text! "  #{line}\n"}
        end
      ensure
        if e.class != SystemExit
	  $cleanup.call if $cleanup
  
          # terminate server
	  Process.kill "INT", $server if $server
	  Process.wait($server) if $server
  
          # optionally save a snapshot
          if ARGV.include? 'save'
            log :snap, 'save'
            Dir.chdir $BASE
            FileUtils.rm_rf "snapshot"
            FileUtils.cp_r "work", "snapshot", :preserve => true
          end
        end
      end
    end
  end
  
  # output results as HTML, after inserting style and toc information
  $x.target![/<style.*?>()/,1] = "\n#{$style.target!.strip.gsub(/^/,' '*6)}\n"
  $x.target!.sub! /<ul(.*?)\/>/,
    "<ul\\1>\n#{$toc.target!.gsub(/^/,' '*6)}    </ul>"
  $x.target!.gsub! '<strong/>', '<strong></strong>'
  log :WRITE, "#{$output}.html"
  open("#{$BASE}/#{$output}.html",'w') do |file| 
    file.write <<-EOF.unindent(4)
      <!DOCTYPE html
      PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
      "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
    EOF
    file.write $x.target!
  end
  
  # run tests
  if $checker
    log :CHECK, "#{$output}.html"
    Dir.chdir $BASE
    STDOUT.puts
    if $checker =~ /^[-\w]+$/
      require File.join($BASE,$checker)
    else
      require $checker
    end
  end
end
