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

server_dir = Dir.pwd

token_filename = "token"
upstream_db_filename = "repos.txt"

if !File.exist?(token_filename)
  `ruby -rsecurerandom -e 'puts SecureRandom.hex(20)' > token`
  puts "I just created a token with value: #{File.read(token_filename)}"
end

token = File.read(token_filename).strip

def load_db(path)
  if !File.exist?(path)
    File.open(path, "w") { |file|
      file << %q{#
# this file contains the list of supported repos by specfile-aggregator
#
# example:
# [repository name of a specfile tree]
# url = git.clone.address
# copr = copr_project_name, separated by commas
#
# [upstream repository name (for continuous packages)]
# url = git.clone.address
# spec = https://address.of.the.spec.git.tree
# copr = copr_project_names, separated by commas

[libratbag-spec]
url = https://github.com/bentiss/libratbag-spec.git
copr = libratbag-sandbox

[libratbag]
url = https://github.com/libratbag/libratbag.git
spec = https://github.com/bentiss/libratbag-spec.git
copr = libratbag-nightly

[ratbagd-spec]
url = https://github.com/bentiss/ratbagd-spec.git
copr = libratbag-sandbox

[ratbagd]
url = https://github.com/libratbag/ratbagd.git
spec = https://github.com/bentiss/ratbagd-spec.git
copr = libratbag-nightly
}
    }
  end

  projects = {}

  current_project = nil
  File.readlines(path).each do |line|
    # comments
    if /\w*#/.match(line)
      next
    end
    # empty lines
    if /^\w*$/.match(line)
      next
    end

    # tags
    m = /\[(.*)\]/.match(line)
    if m
      project = m[1]
      if projects[project]
        puts("duplicate entry '#{project}', skipping")
        current_project = nil
      end
      projects[project] = {}
      projects[project]["url"] = ""
      projects[project]["copr"] = ""
      projects[project]["spec"] = ""
      current_project = project
      next
    end
    if current_project == nil
      next
    end
    key, values = line.split('=', 2)
    key.strip!
    if !projects[current_project][key]
      puts("ignoring unsupported tag '#{key}'.")
      next
    end
    projects[current_project][key] = values.strip
    if key == "copr"
      puts "repo #{current_project} will build in projects '#{projects[current_project]["copr"]}'"
    end
  end

  return projects
end

# make sure the db file is OK
load_db(upstream_db_filename)

configure do
  set :bind, '0.0.0.0'
end

get "/#{token}" do
  Dir.chdir(server_dir)
  repo = "libratbag-spec"
  html_url = "https://github.com/bentiss/libratbag-spec.git"
  puts "Received a push notification for: #{repo}"
  project = get_db_entry(repo, upstream_db_filename)
  copr = project['copr']
  url = project['url']
  if url != html_url
    return halt 500, "Project '#{html_url}' is not valid"
  end
  sync_repo(repo, url, copr)
  update_tar_gz(repo)
  tag_tree(repo)
  release(repo, copr, "--dry-run")
  puts "Updated #{repo}"
  return halt 200, "Updated #{repo}"
end

post '/payload' do
  Dir.chdir(server_dir)
  request.body.rewind
  payload_body = request.body.read
  verify_signature(payload_body, token)
  jdata = JSON.parse(payload_body)
  repo = jdata['repository']['name']
  html_url = jdata['repository']['ssh_url']
  ssh_url = jdata['repository']['html_url']
  project = get_db_entry(repo, upstream_db_filename)
  copr = project['copr']
  url = project['url']
  if url != html_url && url != ssh_url
    return halt 500, "Project '#{html_url}' is not valid"
  end
  puts "Received a push notification for: #{repo}"
  sync_repo(repo, url, copr)
  update_tar_gz(repo)
  tag_tree(repo)
#  push(repo)
  release(repo, copr, "")
  puts "Updated #{repo}"
  return halt 200, "Updated #{repo}"
end

def verify_signature(payload_body, token)
  signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), token, payload_body)
  return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
end

def get_db_entry(repo, db_filename)
  projects = load_db(db_filename)
  return halt 500, "Unknown repository. Please update #{db_filename}" unless projects[repo]
  return projects[repo]
end

def get_key(name)
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

def sync_repo(name, url, copr)
  key = get_key(name)
  if !File.exist?(name)
    clone(key, name, url, copr)
  end
  pull(key, name)
end

def clone(key, name, url, copr)
  curdir = Dir.pwd
  `ssh-agent bash -c 'ssh-add #{key} ; git clone #{url} #{name}'`
  return halt 500, "unable to clone #{name}, check the access rights.\nSsh key used: '#{File.read("#{key}.pub").strip}'\n" unless Dir.exist?(name)
  Dir.chdir(name)
  `git checkout -b copr`
  `git branch --set-upstream-to=origin/master copr`
  `tito init`
  tito_fill_releaser(copr)
  Dir.chdir(curdir)
end

def tito_fill_releaser(copr)
  File.open(".tito/releasers.conf", "w") { |file|
    file.puts("[copr]")
    file.puts("releaser = tito.release.CoprReleaser")
    file.puts("project_name = #{copr}")
  }
  `git add .tito/releasers.conf`
  `git commit -m "fill in tito releasers"`
end

def pull(key, name)
  curdir = Dir.pwd
  Dir.chdir(name)
  `ssh-agent bash -c 'ssh-add #{key} ; git pull'`
  Dir.chdir(curdir)
end

def push(name)
  key = get_key(name)
  curdir = Dir.pwd
  Dir.chdir(name)
  `ssh-agent bash -c 'ssh-add #{key} ; git push origin copr'`
  Dir.chdir(curdir)
end

def update_tar_gz(name)
  curdir = Dir.pwd
  Dir.chdir(name)
  `spectool -g *.spec`
  Dir.chdir(curdir)
end

def tag_tree(name)
  curdir = Dir.pwd
  Dir.chdir(name)
  return halt 200, "already tagged, skipping\n" unless system("tito tag --keep-version --no-auto-changelog")
  # fix the messed up changelog entry
  specfile = Dir["*.spec"][0]
  `git show HEAD~1:#{specfile} > #{specfile}`
  `git commit -a -m "fix the messed up tito changelog entry"`
  Dir.chdir(curdir)
end

def release(name, copr, params)
  curdir = Dir.pwd
  Dir.chdir(name)
  return halt 500, "Can't start the copr build of #{name} in #{copr}" unless system("tito release copr --offline #{params}")
  Dir.chdir(curdir)
end
