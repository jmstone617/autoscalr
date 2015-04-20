require 'optparse'
require 'erb'
require 'logger'
require 'bunny'
require_relative './version'
require_relative './autoscalr'

class MonitorBalancer
	def self.parse_options(args)
		options = {}
		options[:host] = nil
		options[:config] = 'autoscalr.yml'
    options[:lb] = nil
    options[:lb_config_template] = 'haproxy.cfg.erb'
    options[:lb_config] = '/etc/haproxy/haproxy.cfg'
    options[:rhost] = nil
    options[:user] = nil
    options[:password] = nil
    options[:vhost] = nil
		options[:daemonize] = false

		opt_parser = OptionParser.new do |opts|
			opts.banner = "Usage: example.rb [options]"

			opts.separator ""
      opts.separator "Specific options:"

      opts.separator ""
      opts.separator "Common options:"

      # Platform is a required flag, as we need to know which to read credentials from
      opts.on("-h", "--host HOST", [:digitalocean], "The hosting provider you are scaling", "Currently, the only supported provider is digitalocean") do |host|
      	options[:host] = host
      end

      # Config is a required flag, as we need to know what config to read
      opts.on("-c", "--config CONFIG", "The path to a YAML config file") do |config|
      	options[:config] = config
      end

      # Load Balancer file is a required flag, as we need to know where to monitor for load balancer things
      opts.on("-l", "--load-balancer LB", [:haproxy], "The path the file containing load balancer stuff") do |lb|
        options[:lb] = lb
      end

      # Load Balancer Config Template file is a required flag, as we need to know where to monitor for load balancer things
      opts.on("-b", "--load-balancer-template LBC", "The  path the file containing the load balancer template config file") do |lb_config_template|
        options[:lb_config_template] = lb_config_template
      end

      # Load Balancer Config file is a required flag, as we need to know where to monitor for load balancer things
      opts.on("-t", "--load-balancer-config LBC", "The  path the file containing the load balancer config file") do |lb_config|
        options[:lb_config] = lb_config
      end

      opts.on("-r", "--rhost RABBITMQ_HOST", "The server where the RabbitMQ server is running") do |rhost|
        options[:rhost] = rhost
      end

      opts.on("-u", "--user USER", "The RabbitMQ server username") do |user|
        options[:user] = user
      end

      opts.on("-p", "--password PASSWORD", "The RabbitMQ server password") do |password|
        options[:password] = password
      end

      opts.on("-o", "--vhost VHOST", "The RabbitMQ vhost", "Add a new vhost using the Rabbit MQ cli: rabbitmqctl add_vhost vhost_name") do |vhost|
        options[:vhost] = vhost
      end

      opts.on_tail("-d", "--daemonize", "Daemonize this process") do
      	options[:daemonize] = true
      end

      # No argument, shows at tail.  This will print an options summary.
      # Try it and see!
      opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit
      end

      # Another typical switch to print the version.
      opts.on_tail("-v", "--version", "Show version") do
        puts VERSION.dup
        exit
      end
		end # End opt_parser

		opt_parser.parse!(args)

		#Now raise an exception if we have not found a host option
		raise OptionParser::MissingArgument if options[:host].nil?
    raise OptionParser::MissingArgument if options[:lb].nil?
    raise OptionParser::MissingArgument if options[:rhost].nil?
    raise OptionParser::MissingArgument if options[:user].nil?
    raise OptionParser::MissingArgument if options[:password].nil?
    raise OptionParser::MissingArgument if options[:vhost].nil?

    if options[:daemonize] == true
      Process.daemon(true, true)
    end
    Monitor.monitor(load_balancer: options[:lb], 
                    host: options[:host], 
                    config: options[:config], 
                    lb_config_template: options[:lb_config_template], 
                    lb_config: options[:lb_config],
                    rhost: options[:rhost],
                    user: options[:user],
                    password: options[:password],
                    vhost: options[:vhost])

    options
	end # end parse_options()
end # end MonitorBalancer class

class Monitor
  def self.monitor(options={})
    # TODO: Check if the file exists at lb
    # TODO: Raise an error if it doesnt
    # TODO: Actually check the load balancer file.
    autoscalr = Autoscalr.new(options[:host], options[:config])
    conn = ::Bunny.new(host: options[:rhost], user: options[:user], password: options[:password], vhost: options[:vhost])
    conn.start

    channel = conn.create_channel

    exchange = channel.topic('cpu')

    puts " [*] Waiting for messages in #{exchange}. To exit press CTRL+C"

    channel.queue('', exclusive: true).bind(exchange, routing_key: "SOME_REGEX").subscribe(block: true) do |delivery_info, metadata, payload|
      puts "Received message #{payload}, routing key is #{delivery_info.routing_key}, exchange is #{delivery_info.exchange}, sent at time #{metadata.timestamp.to_i}"
      scaled = autoscalr.scale_if_needed(cpu: payload.to_i, hostname: delivery_info.routing_key, timestamp: metadata.timestamp.to_i)

      if scaled
        # Wait 30 seconds for our new instance to be spun up/down
        sleep 30

        # Reload the template HAProxy configuration file
        fn = File.dirname(File.expand_path(__FILE__)) + "/templates/#{options[:lb_config_template]}"
        puts fn
        bn = binding
        bn.local_variable_set(:servers, autoscalr.private_server_ips)
        hap_config = ERB.new(File.read(fn), nil, '-').result(bn)
        # Write the file to the config location
        res = File.open(lb_config, 'w') do |f|
          f << hap_config
        end

        puts "Config is at #{options[:lb_config]}"
        # Restart the haproxy service
        `sudo service haproxy restart`
      end
    end
  end
end


MonitorBalancer.parse_options(ARGV)