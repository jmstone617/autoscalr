# autoscalr
When auto-scaling your infrastructure needs some love

### Introduction:
Autoscalr was born out of a very real need: We had our infrastructure hosted on DigitalOcean but, unlike other hosting providers (read: AWS), we had no turn-key load balancer or auto-scaling functionality.

Enter Autoscalr.

Right now, Autoscalr is built to suite our needs at Notion, but we're always looking to expand this tool to fit other needs and hosting providers, so please contribute! Autoscalr only works with DigitalOcean and HAProxy for now. Also, the autoscale thresholding works mostly on a single primary web server, and uses CPU utilization as the trigger point for scaling up and down.

### Prerequisites:
1. Hosted on DigitalOcean
2. HAProxy as the Load Balancer
3. RabbitMQ server running on same server as HAProxy
4. Git as your SCM system of choice

### What You'll Need:
1. A DigitalOcean Personal API Token (get one here: https://cloud.digitalocean.com/settings/applications)
2. A consistent hostname naming scheme for your servers. (See this post for some advice: http://blog.codeship.com/proper-server-naming-scheme/)

### Before You Get Started:
You’ll need a few external gems that Autoscalr depends on. On your primary web server:
```ruby
gem install barge
gem install bunny —version “>= 1.6.0”
```

On the central server:
```ruby
gem install bunny —version “>= 1.6.0”
```

You’ll also need to install the RabbitMQ server. I would recommend installing this on the same server as your load balancer. Follow these instructions:
http://www.rabbitmq.com/install-debian.html

Then, add a new user to RabbitMQ’s database:
```bash
rabbitmqctl add_user user_name password
```

And a new vhost for that user
```bash
rabbitmqctl add_vhost vhost_name
rabbitmqctl set_permissions -p vhost_name user_name "^.*" ".*" ".*"
```

### Central
Just copy the central/ folder to the server running RabbitMQ. In `monitor_balancer.rb`, be sure to change the routing key for RabbitMQ to something that makes sense for your application. A regex that matches your server naming scheme is a good choice.

### Server
Just copy `send_cpu_util.rb` to a primary web server, and replace the user, password, host, and vhost parameters with the ones you set up above. The host is the IP address where the RabbitMQ server is running. 

It's easiest to just run this script as a cron job. For instance, if you wanted to run this script every 10 minutes, you would simply open up cron with:
```bash
crontab -e
```

And add the following line to the end:
```bash
*/10 * * * * /path/to/ruby /path/to/send_cpu_util.rb
```

### Start Autoscaling!
First, copy autoscalr.yml.example
```bash
cp autoscalr.yml.example autoscalr.yml
```

Open `autoscalr.yml` with your favorite text editor, and fill in the appropriate values. All of the values under the `global` section are the same as the defaults set in `autoscalr.rb`, so you can remove the global block if the defaults work. Also, remove the `ssh_keys` field if you don't want to spin up a new server with SSH keys installed.

An example of how to kick off the autoscalr on your central server could look like this:
```bash
/path/to/ruby /path/to/monitor_balancer.rb -h digitalocean -l haproxy -r 1.1.1.1 -u user -p password -o vhost
```

To run the script as a daemon, just add the `-d` flag to the end.

## Contributing

I hope that you will consider contributing to Autoscalr. 

You will probably want to write tests for your changes. To run the test suite, go into Autoscalr's top-level directory and run `rspec spec/`.

## Bug reports

If you discover a problem with Autoscalr, we would like to know about it. Please use the GitHub issue tracker to add bugs or feature requests.

If you have discovered a security related bug, please do NOT use the GitHub issue tracker. Send an email to developer@getnotion.com.

## TODO:
1. Enable support for user data on DigitalOcean
2. Enable support for multi-server CPU utilization
3. Enable support for other hosting providers (e.g. AWS, Rackspace)
4. Enable support for other load balancers (e.g. nginx)


