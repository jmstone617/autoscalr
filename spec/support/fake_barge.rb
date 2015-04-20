require 'sinatra/base'

class FakeBarge < Sinatra::Base
	post '/v2/droplets' do
    json_response 201
  end

  get '/v2/droplets' do
  	json_response 200, 'droplets.json'
  end

  private
  def json_response(response_code, file_name=nil)
    content_type :json
    status response_code
    path = File.expand_path("../../fixtures/#{file_name}", __FILE__) if file_name
    File.open(path).read if path
  end
end