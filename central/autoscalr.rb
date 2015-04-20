require 'yaml'
require 'logger'
require 'barge'

class Autoscalr
	def initialize(provider, config_file)
		@logger = Logger.new('autoscalr.log')
		@logger.level = Logger::DEBUG

		@provider = provider
		@config_file = config_file

		raise IOError.new("#{@config_file} does not exist.") unless File.exists?(@config_file)
		raise ArgumentError.new("#{@provider} is an unsupported provider. Please use one of: #{providers.inspect}.") unless provider_valid?

		# TODO: Check the validity of the yaml file contents per provider
		@config = YAML.load_file(@config_file)
		@client = build_client

		@min_servers = @config['global']['min_servers'].to_i || 2
		@max_servers = @config['global']['max_servers'].to_i || 20
		@min_cpu_utilization = @config['global']['min_cpu_utilization'].to_i || 30
		@max_cpu_utilization = @config['global']['max_cpu_utilization'].to_i || 80
		@time_threshold = @config['global']['time_threshold'].to_i || 300
	end

	def scale_if_needed(options={})
		scaled = false
		if options.has_key?(:cpu)
			cpu = cpu_utilization(options[:cpu])
			yml_file = File.join(__dir__, 'scaling.yml')
			hostname = options[:hostname]
			time = scaling_started_at(yml_file, hostname)
			now = Time.now.to_i

			#return scaled if scaling_in_progress? yml_file

			if cpu >= @max_cpu_utilization
				@logger.debug "CPU Utilization higher than threshold. Should we scale up?"
				if stored_key?(yml_file, hostname)
					# Has it been longer than the time threshold?
					if (now - time >= @time_threshold && threshold_transgression(yml_file, hostname) == 'max')
						@logger.info "CPU over minimum utilization for #{now - time} seconds. Scaling up..."
						scaled = scale_up

						remove_scale_key(yml_file, hostname) if scaled
					else
						@logger.debug 'It has not been long enough to scale up'
						update_threshold_transgression_type(yml_file, hostname, 'max')
					end
				else
					@logger.debug "Storing scale time #{options[:timestamp]}"
					store_threshold_transgression(yml_file, hostname, options[:timestamp], 'max')
				end
			elsif cpu <= @min_cpu_utilization
				@logger.debug "CPU Utilization lower than threshold. Should we scale down?"
				if stored_key?(yml_file, hostname)
					# Has it been longer than the time threshold?
					if (now - time >= @time_threshold && threshold_transgression(yml_file, hostname) == 'min')
						@logger.info "CPU under minimum utilization for #{now - time} seconds. Scaling down..."
						scaled = scale_down

						remove_scale_key(yml_file, hostname) if scaled
					else
						@logger.debug 'It has not been long enough to scale down'
						update_threshold_transgression_type(yml_file, hostname, 'min')
					end
				else
					@logger.debug "Storing scale time #{options[:timestamp]}"
					store_threshold_transgression(yml_file, hostname, options[:timestamp], 'min')
				end
			else
				@logger.info "No scaling needed. CPU is only at #{cpu}%"

				# Remove the key, as we're not longer above utilization
				remove_scale_key(yml_file, hostname)
			end
		end

		scaled
	end

	def scale_up
		success = false
		
		case @provider
		when :digitalocean
			# Use barge gem to create a new droplet
			options = @config[@provider.to_s].reject do |k, v|
				k == 'token' || k == 'server_prefix' || k == 'environment' || k == 'domain'
			end

			options['name'] = build_hostname(@config[@provider.to_s]['server_prefix'], 
																			@config[@provider.to_s]['region'],
																			@config[@provider.to_s]['environment'], 
																			@config[@provider.to_s]['domain'])

			@logger.debug "Built options hash #{options.inspect}"
			result = @client.droplet.create(options)
			if result.success?
				success = true
				@logger.info "Built new droplet with hostname #{options['name']}"
			else
				@logger.error "Failed to scale up: #{result.message}"
			end
		end

		success
	end

	def scale_down
		success = false

		case @provider
		when :digitalocean
			# Use barge gem to drop the last droplet
			droplets = @client.droplet.all

			server_to_remove = server_to_remove(droplets.droplets, 
																				@config[@provider.to_s]['server_prefix'], 
																				@config[@provider.to_s]['region'],
																				@config[@provider.to_s]['environment'], 
																				@config[@provider.to_s]['domain'])
			@logger.info "Removing server with name #{server_to_remove}" if server_to_remove

			if server_to_remove
				# Find the server's ID
				droplet_id = 0
				droplets.droplets.each do |droplet|
					droplet_id = droplet.id if droplet.name == server_to_remove
				end

				result = @client.droplet.destroy(droplet_id)
				if result.success?
					success = true
					@logger.info "Removed droplet with hostname: #{server_to_remove}"
				else
					@logger.error "Failed to scale down: #{result.message}"
				end
			end
		end

		success
	end

	def cpu_utilization(cmd)
		utilization = 100 - cmd.to_i
		utilization >= 0 ? utilization : 100 + (utilization).abs
	end

	def providers
		[:digitalocean]
	end

	def server_regex
		/\A#{@config[@provider.to_s]['server_prefix']}\d{2}.#{@config[@provider.to_s]['environment']}.#{@config[@provider.to_s]['region']}.#{@config[@provider.to_s]['domain']}/i
	end

	def public_server_ips
		servers('public')
	end

	def private_server_ips
		server_ips('private')
	end

	def build_client
		case @provider
		when :digitalocean
			client = Barge::Client.new(access_token: @config[@provider.to_s]['token'])
		else
			@logger.info "Unable to build client for #{@provider}"
		end
	end

	def build_hostname(server_prefix, region, environment, domain)
		case @provider
		when :digitalocean
			droplets = @client.droplet.all

			count = 0
			droplets.droplets.each do |droplet|
				count += 1 if droplet.name.match server_regex
			end

			# Add one to count
			count += 1
			count_string = count.to_s if count > 9
			count_string = "0#{count}" if count < 10
			"#{server_prefix}#{count_string}.#{environment}.#{region}.#{domain}"
		end
	end

	def server_to_remove(droplets, server_prefix, region, environment, domain)
		last_server = nil

		case @provider
		when :digitalocean
			count = 0
			
			droplets.each do |droplet|
				count += 1 if droplet.name.match server_regex
			end

			if count <= @min_servers
				@logger.warn 'Cannot scale down. Only two servers exist'
			else
				# Select the last  server
				count_string = count.to_s if count > 9
				count_string = "0#{count}" if count < 10

				droplets.each do |droplet|
					last_server = droplet.name if droplet.name.match /\A#{server_prefix}#{count_string}.#{environment}.#{region}.#{domain}/i
				end
			end
		end

		last_server
	end

	def scaling_in_progress?(yml_file)
		if File.exists?(yml_file)
			yaml = YAML.load_file(yml_file)

			return (yaml['scaling'])
		end
	end

	def scaling_in_progress(yml_file, true_or_false)
		if File.exists?(yml_file)
			existing_yaml = YAML.load_file(yml_file)
			
			existing_yaml['scaling'] = true_or_false

			File.open(yml_file, 'w') do |f|
				f << existing_yaml.to_yaml
			end
		end
	end

	def stored_key?(yml_file, a_key)
		if File.exists?(yml_file)
			yaml = YAML.load_file(yml_file)

			return (yaml.has_key?(a_key))
		end
	end

	def store_scale(yml_file, a_key, timestamp)
		if File.exists?(yml_file)
			existing_yaml = YAML.load_file(yml_file)
			return true if existing_yaml.has_key?(a_key)
		end

		yml = {a_key => { 'timestamp' => timestamp }, 'scaling' => true}.to_yaml

		File.open(yml_file, 'w') do |f|
			f << yml
		end
	end

	def store_threshold_transgression(yml_file, a_key, timestamp, threshold_type)
		if File.exists?(yml_file)
			existing_yaml = YAML.load_file(yml_file)
			return true if (existing_yaml.has_key?(a_key) && existing_yaml[a_key]['type'] == threshold_type)
		end

		yml = {a_key => { 'timestamp' => timestamp, 'type' => threshold_type }, 'scaling' => false }.to_yaml

		File.open(yml_file, 'w') do |f|
			f << yml
		end
	end

	def update_threshold_transgression_type(yml_file, a_key, threshold_type)
		if File.exists?(yml_file)
			existing_yaml = YAML.load_file(yml_file)
			return true if (existing_yaml.has_key?(a_key) && existing_yaml[a_key]['type'] == threshold_type)

			existing_yaml[a_key]['type'] = threshold_type

			File.open(yml_file, 'w') do |f|
				f << existing_yaml.to_yaml
			end
		end
	end

	def threshold_transgression(yml_file, a_key)
		transgression = ''

		if File.exists?(yml_file)
			yaml = YAML.load_file(yml_file)

			if yaml.has_key?(a_key)
				transgression = yaml[a_key]['type']
			end 
		end

		transgression
	end

	def remove_scale_key(yml_file, a_key)
		if File.exists?(yml_file)
			yaml = YAML.load_file(yml_file)

			yaml.reject! { |k, v| k == a_key }
			yaml['scaling'] = false

			File.open(yml_file, 'w') do |f|
				f << yaml.to_yaml
			end
		end
	end

	def scaling_started_at(yml_file, a_key)
		if File.exists?(yml_file)
			yaml = YAML.load_file(yml_file)

			return yaml[a_key]['timestamp'] if yaml.has_key? a_key
		end
	end

	private
	def provider_valid?
		providers.include? @provider
	end

	def server_ips(type)
		droplets = @client.droplet.all.droplets

		servers = []
		droplets.each do |droplet|
			droplet.networks.v4.each do |network|
				servers << network.ip_address if ((network.type == type) && (droplet.name.match server_regex))
			end
		end

		servers
	end
end # end Autoscalr class