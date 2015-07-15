#!/usr/bin/env ruby

require 'bundler'
Bundler.require

require 'active_resource'
require 'optparse'
require 'yaml'

class Issue < ActiveResource::Base
  self.format = :xml
end

class SvnRmRep
  SVN='svn'

  def get_rm_ticket(id)
    begin
      Issue.find(id)
    rescue => ex
      nil
    end
  end

  def initialize(v)
    opt = v.getopts('c:r:')
    @revs = opt['r'] || "HEAD:1"
    conf  = opt['c'] || "config.yaml"
    yaml = YAML.load_file(conf)
    @url = yaml["svn-url"]
    raise "#{File.basename($0)} need svn-url in conf file\n" if @url.nil?
    @rm_url = yaml["rm-url"]
    @rm_key = yaml["rm-key"]
    unless @rm_url.nil? and @rm_key.nil?
      raise "#{File.basename($0)} need rm-url(redmine-url) in conf file\n" if @rm_url.nil?
      raise "#{File.basename($0)} need rm-key(redmine-api-key) in conf file\n" if @rm_key.nil?
    end
    Issue.site = @rm_url
    ActiveResource::Base.headers['X-Redmine-API-Key'] = @rm_key
  end

  def svn_diff(rev)
    diffopt = "--diff-cmd diff -x \'-U 0 -b -i -w -B\'"
    add = 0
    del = 0
    out = `#{SVN} diff -c #{rev} #{diffopt} #{@url}`.scrub('?')
    out.split("Index:").each do |part|
      part.split("\n").each do |l|
        del = del + 1 if l =~ /^-(?!-)/
        add = add + 1 if l =~ /^\+(?!\+)/
      end
    end
    return add,del
  end

  def svn_changes
    @changes = []
    tmp = {}
    `#{SVN} log #{@url} -r #{@revs}`.split("\n").each do |l|
      next if l =~ /^-----/
      next if l == ""
      if ( l =~ /^r(\d*)\s\|\s(\S*)\s\|\s(\d{4})-(\d{2})-(\d{2})/ )
        @changes.push tmp unless tmp.size == 0
        tmp = {}
        tmp[:rev] = $1
        tmp[:author] = $2
        tmp[:y] = $3
        tmp[:m] = $4
        tmp[:d] = $5
        (add,del) = svn_diff(tmp[:rev])
        tmp[:add] = add
        tmp[:del] = del
      else
        if l =~ /#(\d*)/
          if tmp[:ticket].nil?
            tmp[:ticket] = [$1]
          else
            tmp[:ticket].push $1
          end
        end
      end
    end
  end

  def print_changes
    print " rev| author   | date     | add| del| ticket \n"
    print " ---+----------+----------+----+----+-----------\n"
    @changes.each do |d|
      ticket = d[:ticket].join(":") unless d[:ticket].nil?
      printf "%4s|%10s|%s-%s-%s|%4d|%4d|%s\n",d[:rev],d[:author],d[:y],d[:m],d[:d],d[:add],d[:del],ticket
    end
    print "\n\n"
  end

  def print_month_changes
    rep = {}
    @changes.each do |d|
      k = d[:y] + "-" + d[:m]
      if rep[k].nil?
        rep[k] = {}
        rep[k][:add] = d[:add]
        rep[k][:del] = d[:del]
        rep[k][:cnt] = 1
      else
        rep[k][:add] = rep[k][:add] + d[:add]
        rep[k][:del] = rep[k][:del] + d[:del]
        rep[k][:cnt] = rep[k][:cnt] + 1
      end
    end
    print " month      | commits | add    | del    | delta  \n"
    print " -----------+---------+--------+--------+--------\n"
    rep.sort {|(k1, v1), (k2, v2)| k2 <=> k1 }.each do |k,v|
      printf " %-10s | %7d | %+6d | %+6d | %+6d\n",k,v[:cnt],v[:add],v[:del] * -1,v[:add] - v[:del]
    end
    print "\n\n"
  end

  def print_author_changes
    rep = {}
    @changes.each do |d|
      k = d[:author]
      if rep[k].nil?
        rep[k] = {}
        rep[k][:add] = d[:add]
        rep[k][:del] = d[:del]
        rep[k][:cnt] = 1
      else
        rep[k][:add] = rep[k][:add] + d[:add]
        rep[k][:del] = rep[k][:del] + d[:del]
        rep[k][:cnt] = rep[k][:cnt] + 1
      end
    end
    print " author     | commits | add    | del    | delta  \n"
    print " -----------+---------+--------+--------+--------\n"
    rep.sort {|(k1, v1), (k2, v2)| k1 <=> k2 }.each do |k,v|
      printf " %-10s | %7d | %+6d | %+6d | %+6d\n",k,v[:cnt],v[:add],v[:del] * -1,v[:add] - v[:del]
    end
    print "\n\n"
  end

  def print_ticket_changes
    rep = {}
    @changes.each do |d|
      next if d[:ticket].nil?
      size = d[:ticket].size
      d[:ticket].each do |k|
        if rep[k].nil?
          rep[k] = {}
          rep[k][:add] = d[:add] / size
          rep[k][:del] = d[:del] /size
          rep[k][:cnt] = 1
        else
          rep[k][:add] = rep[k][:add] + (d[:add] / size)
          rep[k][:del] = rep[k][:del] + (d[:del] / size)
          rep[k][:cnt] = rep[k][:cnt] + 1
        end
      end
    end
    print " ticket     | commits | add    | del    | delta  | start      | end        | diff   \n"
    print " -----------+---------+--------+--------+--------+------------+------------+--------\n"
    rep.sort {|(k1, v1), (k2, v2)| k2 <=> k1 }.each do |k,v|
      printf " %-10s | %7d | %+6d | %+6d | %+6d |",k,v[:cnt],v[:add],v[:del] * -1,v[:add] - v[:del]
      t = get_rm_ticket(k)
      if t.nil?
        printf "            |            |\n"
      else
        st = DateTime.parse(t.created_on)
        printf " %s |",st.strftime("%Y-%m-%d")
        if t.closed_on.nil?
          printf "            |  \n"
        else
          ed = DateTime.parse(t.closed_on)
          df = (ed - st).to_i
          printf " %s | %+6d \n",ed.strftime("%Y-%m-%d"),df
        end
      end
    end
    print "\n\n"
  end
end

sc = SvnRmRep.new(ARGV)
sc.svn_changes
sc.print_changes
sc.print_month_changes
sc.print_author_changes
sc.print_ticket_changes

