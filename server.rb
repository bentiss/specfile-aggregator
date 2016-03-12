require 'sinatra'
require 'json'

token_filename = "token"

if !File.exist?(token_filename)
	`ruby -rsecurerandom -e 'puts SecureRandom.hex(20)' > token`
	puts "I just created a token with value: #{File.read(token_filename)}"
end

token = File.read(token_filename).strip
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
  puts "Received a push notification for: #{repo}"
  sync_repo(repo, url)
  update_tar_gz(repo)
end

def verify_signature(payload_body, token)
  signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), token, payload_body)
  return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
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
  Dir.chdir(curdir)
end

def pull(key, name)
  curdir = Dir.pwd
  Dir.chdir(name)
  `ssh-agent bash -c 'ssh-add #{key} ; git pull'`
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
