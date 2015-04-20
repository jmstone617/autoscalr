require 'spec_helper'
require_relative '../central/autoscalr'

RSpec.describe Autoscalr do
	context 'with invalid arguments' do
		it 'raises an ArgumentError error for an invalid provider' do
			allow(File).to receive(:exists?).and_return(true)

			expect {
				Autoscalr.new(:not_do, '/path/to/config')
			}.to raise_error(ArgumentError, 'not_do is an unsupported provider. Please use one of: [:digitalocean].')
		end

		it 'raises a NoFile exception if the config file does not exist' do
			expect {
				Autoscalr.new(:digitalocean, '/path/to/config')
			}.to raise_error(IOError, '/path/to/config does not exist.')
		end
	end

	context 'with valid arguments' do
		context 'for provider digitalocean' do
			before(:each) do
				allow(File).to receive(:exists?).and_return(true)
				path = File.expand_path('../../central/autoscalr.yml', __FILE__)
				@autoscaler = Autoscalr.new(:digitalocean, path)
			end

			it 'creates the client' do
				expect(@autoscaler.build_client).to be_kind_of(Barge::Client)
			end

			context 'for a valid config file' do
				it 'builds the proper hostname' do
					expect(@autoscaler.build_hostname('app', 'nyc1', 'staging', 'example.com')).to eq('app03.staging.nyc1.example.com')
				end

				it 'selects the proper last server for removal' do
					droplets = []
					3.times do |t|
						hash = {name: "app0#{t+1}.staging.nyc1.example.com"}
						droplets << Hashie::Mash.new(hash)
					end
					expect(@autoscaler.server_to_remove(droplets, 'app', 'nyc1', 'staging', 'example.com')).to eq('app03.staging.nyc1.example.com')
				end

				it 'will not scale down if the number of servers is below the minimum' do
					droplets = []
					2.times do |t|
						hash = {name: "app0#{t+1}.staging.nyc1.example.com"}
						droplets << Hashie::Mash.new(hash)
					end
					expect(@autoscaler.server_to_remove(droplets, 'app', 'nyc1', 'staging', 'example.com')).to be_nil
				end

				it 'returns the CPU utilization when it is under 100' do
					expect(@autoscaler.cpu_utilization(67)).to eq(33)
				end

				it 'returns the CPU utilization when it is equal to 100' do
					expect(@autoscaler.cpu_utilization(100)).to eq(0)
				end

				it 'returns the CPU utilization when it is over 100' do
					expect(@autoscaler.cpu_utilization(110)).to eq(110)
				end

				context '#stored_key?' do
					before(:each) do
						@path = File.expand_path('../fixtures/scaling.yml', __FILE__)
					end

					it 'returns true if the key does exist' do
						@autoscaler.store_scale(@path, 'app01.staging.nyc1.example.com', '123456')
						expect(@autoscaler.stored_key?(@path, 'app01.staging.nyc1.example.com')).to be_truthy
					end

					it 'returns false if the key does not exist' do
						expect(@autoscaler.stored_key?(@path, 'app02.staging.nyc1.example.com')).to be_falsey
					end
				end

				context '#store_scale' do
					before(:each) do
						@path = File.expand_path('../fixtures/scaling.yml', __FILE__)
					end

					it 'should create the file' do
						@autoscaler.store_scale(@path, 'app03.staging.nyc1.example.com', '123456')
						expect(YAML.load_file(@path).has_key?('app03.staging.nyc1.example.com')).to be_truthy
					end
				end

				context '#scaling_started_at' do
					before(:each) do
						@path = File.expand_path('../fixtures/scaling.yml', __FILE__)
					end

					it 'returns the timestamp in seconds' do
						@autoscaler.store_scale(@path, 'app03.staging.nyc1.example.com', '123456')
						expect(@autoscaler.scaling_started_at(@path, 'app03.staging.nyc1.example.com')).to eq('123456')
					end
				end

				context '#remove_scale_key' do
					before(:each) do
						@path = File.expand_path('../fixtures/scaling.yml', __FILE__)
					end

					it 'removes the given key' do
						@autoscaler.store_scale(@path, 'app03.staging.nyc1.example.com', '123456')
						@autoscaler.remove_scale_key(@path, 'app03.staging.nyc1.example.com')
						expect(YAML.load_file(@path).has_key?('app03.staging.nyc1.example.com')).to be_falsey
					end
				end
			end
		end
	end
end