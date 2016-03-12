#
#  Copyright (c) 2016 Benjamin Tissoires <benjamin.tissoires@gmail.com>
#  Copyright (c) 2016 Red Hat, Inc.
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <http://www.gnu.org/licenses/>.

require 'sinatra'
require 'json'

token_filename = "token"
upstream_db_filename = "upstream_repo.txt"

if !File.exist?(token_filename)
	`ruby -rsecurerandom -e 'puts SecureRandom.hex(20)' > token`
	puts "I just created a token with value: #{File.read(token_filename)}"
end

if !File.exist?(upstream_db_filename)
	File.open(upstream_db_filename, "w") { |file|
		file.puts("# this file contains keys/values of upstream repos and matching specfile repositories")
		file.puts("#")
		file.puts("# example:")
		file.puts("# [copr project name]")
		file.puts("# libratbag = https://github.com/bentiss/libratbag-spec.git")
	}
end

token = File.read(token_filename).strip
upstream_db = {}

current_copr = nil
File.readlines(upstream_db_filename).each do |line|
	if /\w*#/.match(line)
		next
	end
	if /^\w*$/.match(line)
		next
	end
	m = /\[(.*)\]/.match(line)
	if m
		current_copr = m[1]
		if !upstream_db[current_copr]
			upstream_db[current_copr] = {}
		end
		next
	end
	if !current_copr
		puts("error in database '#{upstream_db_filename}'")
		exit 1
	end
	repo, upstream = line.split('=', 2)
	repo.strip!
	upstream_db[current_copr][repo] = upstream.strip
	puts "repo #{repo} matches upstream #{upstream_db[current_copr][repo]} in project '#{current_copr}'"
end

configure do
  set :bind, '0.0.0.0'
end

post '/payload' do
  request.body.rewind
  payload_body = request.body.read
  verify_signature(payload_body, token)
  jdata = JSON.parse(payload_body)
  repo = jdata['repository']['name']
#  url = jdata['repository']['ssh_url']
  url = jdata['repository']['url']
  copr = get_copr(repo, upstream_db)
  puts "Received a push notification for: #{repo}"
  sync_repo(repo, url)
  update_tar_gz(repo)
  tag_tree(repo)
#  push(repo)
  puts "Updated #{repo}"
  return halt 200, "Updated #{repo}"
end

def verify_signature(payload_body, token)
  signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), token, payload_body)
  return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
end

def get_copr(repo, upstream_db)
  upstream_db.each do |copr, entries|
    if entries[repo]
      return copr
    end
    entries.each do |upstream, specfile|
      if /#{repo}[\.git]*$/.match(specfile)
        return copr
      end
    end
  end
  return halt 500, "Unknown repository. Please update #{upstream_db_filename}"
end

def get_key()
  key = "#{Dir.pwd}/keys/id_rsa"
  if !File.exist?(key)
    puts "generating a key in #{key}"
    Dir.mkdir("keys")
    `ssh-keygen -f #{key} -N ""`
    puts "please make sure to add the following key to your #{name} project"
    puts File.read("#{key}.pub")
    return halt 500, "please make sure to add the following key to your #{name} project:\n    '#{File.read("#{key}.pub").strip}'"
  end
  return key
end

def sync_repo(name, url)
  key = get_key()
  if !File.exist?(name)
    clone(key, name, url)
  end
  pull(key, name)
end

def clone(key, name, url)
  curdir = Dir.pwd
  `ssh-agent bash -c 'ssh-add #{key} ; git clone #{url} #{name}'`
  return halt 500, "unable to clone #{name}, check the access rights.\nSsh key used: '#{File.read("#{key}.pub").strip}'\n" unless Dir.exist?(name)
  Dir.chdir(name)
  `git checkout -b copr`
  `git branch --set-upstream-to=origin/master copr`
  `git annex init`
  `tito init`
  tito_switch_to_git_annex()
  Dir.chdir(curdir)
end

def tito_switch_to_git_annex()
  text = File.read(".tito/tito.props")
  new_contents = text.gsub(/tito\.builder\.Builder/, "tito.builder.GitAnnexBuilder")
  File.open(".tito/tito.props", "w") {|file| file.puts new_contents }
  `git commit -a -m "switch tito to use git annex"`
end

def pull(key, name)
  curdir = Dir.pwd
  Dir.chdir(name)
  `ssh-agent bash -c 'ssh-add #{key} ; git pull'`
  Dir.chdir(curdir)
end

def push(name)
  key = get_key()
  curdir = Dir.pwd
  Dir.chdir(name)
  `ssh-agent bash -c 'ssh-add #{key} ; git push origin copr'`
  Dir.chdir(curdir)
end

def update_tar_gz(name)
  curdir = Dir.pwd
  Dir.chdir(name)
  `spectool -l *.spec`.split('\n').each do |source|
    n, url = source.split()
    if !File.exist?(File.basename(url))
      puts "downloading #{url}"
      `git annex addurl --file=#{File.basename(url)} #{url}`
      `git commit -a -m "Add #{url}"`
    end
  end
  Dir.chdir(curdir)
end

def tag_tree(name)
  curdir = Dir.pwd
  Dir.chdir(name)
  return halt 200, "already tagged, skipping\n" unless system("tito tag --keep-version --no-auto-changelog")
  Dir.chdir(curdir)
end
