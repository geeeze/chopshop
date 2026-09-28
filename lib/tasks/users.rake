# Password-only user management. There is no username: a handle is an internal
# key for scoping, and the password is the identity a user logs in with.
namespace :users do
  desc "Add a user. Usage: bin/rails 'users:add[handle,password]'"
  task :add, %i[handle password] => :environment do |_task, args|
    handle = args[:handle].to_s.strip
    password = args[:password].to_s
    if handle.blank? || password.blank?
      abort "usage: bin/rails 'users:add[handle,password]'"
    end

    if User.exists?(handle: handle)
      puts "user #{handle} already exists (password unchanged)"
    else
      User.create!(handle: handle, password: password)
      puts "created user #{handle}"
    end
  end

  desc "List user handles (never digests). Usage: bin/rails users:list"
  task list: :environment do
    User.order(:handle).pluck(:handle).each { |handle| puts handle }
  end
end
