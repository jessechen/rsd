require "rubygems"
require "bundler"
Bundler.require(:default, ENV["RACK_ENV"] || :development)
Dir[File.dirname(__FILE__) + '/lib/*.rb'].each {|file| require file }

configure do
  RACK_ENV = (ENV['RACK_ENV'] || :development).to_sym
  connections = {
    :development => "postgres://localhost/rcdir",
    :test => "postgres://postgres@localhost/rcdir_test",
    :production => ENV['DATABASE_URL']
  }

  unless RACK_ENV.eql? :development
    # Force HTTPS
    use Rack::SslEnforcer
  end

  url = URI(connections[RACK_ENV])
  options = {
    :adapter => url.scheme,
    :host => url.host,
    :port => url.port,
    :database => url.path[1..-1],
    :username => url.user,
    :password => url.password
  }

  case url.scheme
  when "sqlite"
    options[:adapter] = "sqlite3"
    options[:database] = url.host + url.path
  when "postgres"
    options[:adapter] = "postgresql"
  end
  set :database, options

  use Rack::Session::Cookie, :key => 'rack.session',
    :path => '/',
    :expire_after => 86400, # 1 day
    :secret => ENV['SESSION_SECRET'] || '*&(^B234'

  use OmniAuth::Builder do
    provider :recurse_center, ENV['RC_ID'], ENV['RC_SECRET']
  end
end

# God I love filters!
before do
  # pass the filter if still in auth phase
  pass if /^\/(auth\/|logout).*/.match(request.path_info)

  # setup current_user if the user is logged in
  if session[:uid]
    @current_user = User.where(id: session[:uid]).first
  else
    redirect "/auth/recurse_center"
  end
end

get "/" do
  @services = Service.all
  @users = User.all

  erb :index
end

get "/user/:id" do
  @user = User.where(id: params[:id]).first

  if @user.nil?
    error 404
  else
    erb :user
  end
end

get "/edit/account/:account_id" do
  @account = Account.find(params[:account_id])
  error 403 if session[:uid] != @account.user_id

  @service = Service.find(@account.service_id)

  if @account.nil? or @service.nil?
    error 404
  else
    erb :edit
  end
end

post "/edit/account/:account_id" do
  @account = Account.find(params[:account_id])
  error 403 if session[:uid] != @account.user_id

  service_name = params["service"].downcase
  if service_name.empty?
    error 400
  end


  @account.uri = params["uri"]
  @account.mobile_uri = params["mobile_uri"]
  @account.save

  redirect "/user/#{@account.user_id}"
end

get "/delete/account/:account_id" do
  account = Account.find(params[:account_id])
  error 403 if session[:uid] != account.user_id

  account.destroy
  redirect "/user/#{account.user_id}"
end

get "/service/:name" do
  @service = Service.where(name: params[:name]).first

  if @service.nil?
    error 404
  else
    erb :service
  end
end

get "/add/account" do
  erb :add_account
end

post "/add/account" do
  service_id = params["service"]
  if service_id.nil? or service_id.empty?
    error 400
  end

  @service = Service.find(service_id.to_i)

  @account = Account.new
  @account.user = @current_user
  @account.service = @service

  # TODO: Verify params
  @account.uri = params["uri"]
  @account.mobile_uri = params["mobile_uri"]
  @account.save

  redirect "/user/#{session[:uid]}"
end


get "/add/service" do
  erb :add_service
end

post "/add/service" do
  service_name = params["name"].downcase
  if service_name.empty?
    error 400
  end

  @service = Service.find_or_create_by(name: service_name)
  url = params["url"]
  # The URI parsing library doesn't handle URIs without protocols. Sigh.
  url = "http://#{url}" unless url.match '//'
  @service["url"] = url

  @service.save

  redirect "/"

end

%w(get post).each do |method|
  send(method, "/auth/:provider/callback") do
    # https://github.com/intridea/omniauth/wiki/Auth-Hash-Schema
    session[:uid] = env["omniauth.auth"]["uid"]
    session[:token] = env["omniauth.auth"]["credentials"]["token"]


    u = User.find_or_create_by(id: session[:uid])
    u.name = env["omniauth.auth"]["info"]["name"]
    u.image = env["omniauth.auth"]["info"]["image"]
    u.batch = env["omniauth.auth"]["info"]["batch"]["name"]
    u.save

    redirect "/"
  end
end

get "/logout" do
  session[:uid] = nil
  redirect "/"
end

error 400..510 do
  @code = response.status
  erb :error
end
