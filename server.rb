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
  puts "Received a push notification for: #{repo}"
end

def verify_signature(payload_body, token)
  signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), token, payload_body)
  return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
end
