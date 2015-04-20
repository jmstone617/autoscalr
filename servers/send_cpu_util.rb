require 'bunny'
require 'socket'

class CpuMonitor
	def self.monitor

		conn = Bunny.new(user: 'USER', password: 'PASSWORD', vhost: 'VHOST', host: 'HOST')
		conn.start

		ch = conn.create_channel
		exchange = ch.topic("cpu")

		cpu = `(vmstat|tail -1|awk '{print $15}')`.strip.to_i
		hostname = `hostname`.strip
		exchange.publish(cpu.to_s, routing_key: hostname, timestamp: Time.now.to_i)

		puts " [x] Sent CPU Utilization #{cpu} to routing key #{hostname}"
		conn.close
	end
end

CpuMonitor.monitor