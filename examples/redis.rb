$: << File.join(File.dirname(__FILE__), '..', 'lib')
require 'rubygems'
require 'bundler'

Bundler.setup

require 'em-synchrony'
require 'em-synchrony/em-redis'
require 'ftpd'

class ExampleFTPServer < FTPServer

  def file_data_key(path)
    "ftp:data:#{path}"
  end

  def directory_key(path)
    "ftp:dir:#{path}"
  end

  def change_dir(path)
    path == "/" || $redis.sismember(directory_key(File.dirname(path)), File.basename(path) + "/")
  end

  def dir_contents(path)
    response = $redis.smembers(directory_key(path))
    files = response.map do |key|
      name, size = key.sub(/ftp:\//, '').sub(%r{/$}, '')
      dir = key.match(%r{/$})
      DirectoryItem.new(
        :name => name,
        :directory => dir,
        :size => size
      )
    end
  end

  def authenticate(user, pass)
    true
  end

  def get_file(path)
    $redis.get(file_data_key(path))
  end

  def can_put_file(path)
    true
  end

  def put_file(path, data)
    $redis.set(file_data_key(path), data)
    $redis.sadd(directory_key(File.dirname(path)), File.basename(path))
    true
  end

  def delete_file(path)
    $redis.del(file_data_key(path))
    $redis.srem(directory_key(File.dirname(path)), File.basename(path))
    true
  end


  def delete_dir(path)
    ($redis.keys(directory_key(path + "/*") + $redis.keys(file_data_key(path + "/*")))).each do |key|
      $redis.del(key)
    end
    $redis.srem(directory_key(File.dirname(path), File.basename(path) + "/"))
    true
  end

  def move_file(from, to)
    $redis.rename(file_data_key(from), file_data_key(to))
    $redis.srem(directory_key(File.dirname(from)), File.basename(from))
    $redis.sadd(directory_key(File.dirname(to)), File.basename(to))
  end

  def move_dir(from, to)
    if $redis.exists(directory_key(from))
      $redis.rename(directory_key(from), directory_key(to))
    end
    $redis.srem(directory_key(File.dirname(from)), File.basename(from) + "/")
    $redis.sadd(directory_key(File.dirname(to)), File.basename(to) + "/")
    $redis.keys(directory_key(from + "/*")).each do |key|
      new_key = directory_key(File.dirname(to)) + key.sub(directory_key(File.dirname(from)), '')
      $redis.rename(key, new_key)
    end
    $redis.keys(file_data_key(from + "/*")).each do |key|
      new_key = file_data_key(to) + key.sub(file_data_key(from), '/')
      $redis.rename(key, new_key)
    end
  end

  def rename(from, to)
    if $redis.sismember(directory_key(File.dirname(from)), File.basename(from))
      move_file(from, to)
    elsif $redis.sismember(directory_key(File.dirname(from)), File.basename(from) + '/')
      move_dir(from, to)
    else
      false
    end
  end

  def make_dir(path)
    $redis.sadd(directory_key(File.dirname(path)), File.basename(path) + "/")
    true
  end

end

# signal handling, ensure we exit gracefully
trap "SIGCLD", "IGNORE"
trap "INT" do
  puts "exiting..."
  puts
  EventMachine::run
  exit
end

EM.synchrony do
  $redis = EM::Protocols::Redis.connect
  puts "Starting ftp server on 0.0.0.0:5555"
  EventMachine::start_server("0.0.0.0", 5555, ExampleFTPServer)
end
