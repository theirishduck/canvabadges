begin
  require 'rubygems'
rescue LoadError
  puts "You must install rubygems to run this example"
  raise
end

begin
  require 'bundler/setup'
rescue LoadError
  puts "to set up this example, run these commands:"
  puts "  gem install bundler"
  puts "  bundle install"
  raise
end

require 'sinatra'
require 'oauth'
require 'json'
require 'dm-core'
require 'dm-migrations'
require 'nokogiri'
require 'oauth/request_proxy/rack_request'
require 'ims/lti'
require 'digest/md5'

require './lib/models.rb'
require './lib/oauth.rb'

# sinatra wants to set x-frame-options by default, disable it
disable :protection
# enable sessions so we can remember the launch info between http requests, as
# the user takes the assessment
enable :sessions

get "/" do
  return message("Canvabadges are cool")
end

head "/badges/:course_id/:user_id/:code.json" do
  badge_data(params)
end

def badge_data(params)
  badge = Badge.first(:course_id => params[:course_id], :user_id => params[:user_id], :nonce => params[:code])
  headers 'Content-Type' => 'application/json'
  badge.badge_url = "https://#{request.host_with_port}" + badge.badge_url if badge.badge_url.match(/^\//)
  if badge
    return {
      :recipient => badge.recipient,
      :salt => badge.salt, 
      :issued_on => badge.issued.strftime("%Y-%m-%d"),
      :badge => {
        :version => "0.5.0",
        :name => badge.name,
        :image => badge.badge_url,
        :description => badge.description,
        :criteria => "/badges/#{badge.id}/criteria",
        :issuer => {
          :origin => "https://#{request.host_with_port}",
          :name => "Canvabadges",
          :org => "Instructure, Inc.",
          :contact => "support@instructure.com"
        }
      }
    }.to_json
  else
    return "Not Found"
  end
end

# badge details permalink
get "/badges/:course_id/:user_id/:code.json" do
  badge_data(params)
end

# eventually the teacher will use this to configure badge acceptance criteria
post "/badge_check/:course_id/:user_id/settings" do
  if params['course_id'] != session['course_id'] || params['user_id'] != session['user_id']
    return error("Invalid tool load")
  end
  if session['edit_privileges']
    course_config = CourseConfig.first(:course_id => params['course_id'])
    course_config ||= CourseConfig.new(:course_id => params['course_id'])
    settings = JSON.parse(course_config.settings || "{}")
    settings[:badge_url] = params['badge_url']
    settings[:badge_url] = "/badges/default.png" if !settings[:badge_url] || settings[:badge_url].empty?
    settings[:badge_name] = params['badge_name']
    settings[:badge_description] = params['badge_description']
    settings[:min_percent] = params['min_percent'].to_f
    course_config.settings = settings.to_json
    course_config.save
    redirect to("/badge_check/#{params['course_id']}/#{session['user_id']}")
  else
    return error("You can't edit this")
  end
end

# manually award a user with the course's badge
post "/badges/:course_id/:user_id" do
  if params['course_id'] != session['course_id']
    return error("Invalid tool load")
  end
  course_config = CourseConfig.first(:course_id => params['course_id'])
  user_config = UserConfig.first(:user_id => session['user_id'])
  settings = course_config && JSON.parse(course_config.settings || "{}")
  if course_config && settings && settings['badge_url'] && settings['min_percent']
    if !session['edit_privileges']
      return error("You don't have permission to award this badge")
    end
    json = api_call("/api/v1/courses/#{params['course_id']}/users?enrollment_type=student&include[]=email", user_config)
    student = json.detect{|e| e['id'] == params['user_id'].to_i }
    if student
      badge = Badge.first(:user_id => params['user_id'], :course_id => params['course_id'])
      badge ||= Badge.new(:user_id => params['user_id'], :course_id => params['course_id'])
      badge.name = settings['badge_name']
      badge.description = settings['badge_description']
      badge.badge_url = settings['badge_url']
      badge.issued = DateTime.now
      badge.salt = Time.now.to_i.to_s
      badge.email = student['email']
      sha = Digest::SHA256.hexdigest(student['email'] + badge.salt)
      badge.recipient = "sha256$#{sha}"
      badge.nonce = Digest::MD5.hexdigest(badge.salt + rand.to_s)
      badge.manual_approval = true
      badge.save
      
      redirect to("/badge_check/#{params['course_id']}/#{session['user_id']}")
    else
      return error("That user is not a student in this course")
    end
  else
    return error("This badge has not been configured yet")
  end
end

get "/badges/:badge_id/criteria" do
  badge = Badge.first(:id => params['badge_id'])
  if !badge
    return "Badge not found"
  end
  course_config = CourseConfig.first(:course_id => badge.course_id)
  settings = course_config && JSON.page(course_config.settings || "{}")
  html = header
  html += badge_description(settings)
  html += "<p><img src='/check.gif'/> This user completed the requirements necessary to receive this badge</p>"
  html += footer
  html
end

# the magic page, APIs it up to make sure the user has done what they need to,
# shows the results and lets them add the badge if they're done
get "/badge_check/:course_id/:user_id" do
  if params['course_id'] != session['course_id'] || params['user_id'] != session['user_id']
    return error("Invalid tool load")
  end
  user_config = UserConfig.first(:user_id => params['user_id'])
  if user_config
    course_config = CourseConfig.first(:course_id => params['course_id'])
    settings = course_config && JSON.parse(course_config.settings || "{}")
    if course_config && settings && settings['badge_url'] && settings['min_percent']
      json = api_call("/api/v1/courses/#{params['course_id']}?include[]=total_scores", user_config)
      return unless json
      
      student = json['enrollments'].detect{|e| e['type'] == 'student' }
      student['computed_final_score'] ||= 0 if student
      html = header
      html += badge_description(settings)
      if student
        badge = Badge.first(:user_id => params['user_id'], :course_id => params['course_id'])
        if !badge && student['computed_final_score'] >= settings['min_percent']
          badge = Badge.new(:user_id => params['user_id'], :course_id => params['course_id'])
          badge.name = settings['badge_name']
          badge.email = session['email']
          badge.description = settings['badge_description']
          badge.badge_url = settings['badge_url']
          badge.issued = DateTime.now
          badge.salt = Time.now.to_i.to_s
          sha = Digest::SHA256.hexdigest(session['email'] + badge.salt)
          badge.recipient = "sha256$#{sha}"
          badge.nonce = Digest::MD5.hexdigest(badge.salt + rand.to_s)
          badge.save
        end
        if badge
          html += "<h3>You've earned this badge!</h3>"
          if !badge.manual_approval
            html += "To earn this badge you needed #{settings['min_percent']}%, and you have #{student['computed_final_score'].to_f}% in this course right now."
            html += "<div class='progress progress-success progress-striped progress-big'><div class='tick' style='left: " + (3 * settings['min_percent']).to_i.to_s + "px;'></div><div class='bar' style='width: " + student['computed_final_score'].to_i.to_s + "%;'></div></div>"
          end
          url = "https://#{request.host_with_port}/badges/#{params['course_id']}/#{params['user_id']}/#{badge.nonce}.json"
          html += "<button class='btn btn-primary btn-large' id='redeem' rel='#{url}'><span class='icon-plus icon-white'></span> Add this Badge to your Backpack</button>"
        else
          html += "<h3>You haven't earn this badge yet</h3>"
          html += "To earn this badge you need #{settings['min_percent']}%, but you only have #{student['computed_final_score'].to_f}% in this course right now."
          html += "<div class='progress progress-danger progress-striped progress-big'><div class='tick' style='left: " + (3 * settings['min_percent']).to_i.to_s + "px;'></div><div class='bar' style='width: " + student['computed_final_score'].to_i.to_s + "%;'></div></div>"
        end
      else
        html += "<h3>You are not a student in this course, so you can't earn this badge</h3>"
      end
      if session['edit_privileges']
        html += student_list_html(user_config, course_config)
        html += edit_course_html(params['course_id'], params['user_id'], course_config)
      end
      html += footer
      return html
    else
      if session['edit_privileges']
        html = header
        html += student_list_html(user_config, course_config)
        html += edit_course_html(params['course_id'], params['user_id'], course_config)
        html += footer
        return html
      else
        return message("Your teacher hasn't set up this badge yet")
      end
    end
  else
    return error("Invalid user session")
  end
end

def badge_description(settings)
  html = ""
  html += "<img src='" + settings['badge_url'] + "' style='float: left; margin-right: 20px;' class='thumbnail'/>"
  html += "<h2>#{settings['badge_name'] || "Unnamed Badge"}</h2>"
  html += "<p>#{settings['badge_description']}</p><div style='clear: left; padding-bottom: 10px;'></div>"
  html
end

def api_call(path, user_config, post_params=nil)
  url = "https://#{user_config.host}/" + path
  url += (url.match(/\?/) ? "&" : "?") + "access_token=#{user_config.access_token}"
  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = Net::HTTP::Get.new(uri.request_uri)
  response = http.request(req)
  json = JSON.parse(response.body)
  if response.code != "200"
    oauth_dance(user_config.host)
    false
  else
    json
  end
end

def student_list_html(user_config, course_config)
  settings = JSON.parse((course_config && course_config.settings) || "{}")
  if settings['min_percent']
    json = api_call("/api/v1/courses/#{course_config.course_id}/students", user_config)
    if json.is_a?(Array) && json.length > 0
      badges = Badge.all(:course_id => course_config.course_id)
      html = <<-HTML
        <table class="table table-bordered table-striped" style='margin: 25px 0 15px 0;'>
          <thead>
            <tr>
              <th>Student</th>
              <th>Earned</th>
              <th>Issued</th>
          </thead>
          <tbody>
      HTML
      json.each do |student|
        badge = badges.detect{|b| b.user_id.to_i == student['id'] }
        html += <<-HTML
          <tr>
            <td>#{student['name']}</td>
            <td style='width: 200px;'>
        HTML
        if badge && badge.manual_approval
          html += "<img src='/add.png' alt='manually awarded' title='manually awarded'/>"
        elsif badge
          html += "<img src='/check.gif' alt='earned' title='earned'/>"
        else
          html += <<-HTML
            <img src='/redx.png' alt='not earned' class='earn_badge' title='not earned. click to manually award'/>
            <form class='form form-inline' method='POST' action='/badges/#{course_config.course_id}/#{student['id']}' style='visibility: hidden; display: inline; margin-left: 10px;'>
              <button class='btn btn-primary' type='submit'><span class='icon-check icon-white'></span> Award Badge</button>
            </form>
          HTML
        end
        html += <<-HTML
            <td>#{(badge && badge.issued.strftime('%b %e, %Y')) || "&nbsp;"}</td>
          </tr>
        HTML
      end
      html += "</tbody></table>"
      return html
    else
      return "No students are enrolled in this course"
    end
  end
  return ""
end

def edit_course_html(course_id, user_id, course_config)
  settings = JSON.parse((course_config && course_config.settings) || "{}")
  <<-HTML
    <form class='well form-horizontal' style="margin-top: 15px;" method="post" action="/badge_check/#{course_id}/#{user_id}/settings">
    <h2>Badge Settings</h2>
    <img src='<%= settings['badge_url'] || '/badges/default.png' %>' style='float: left; margin-right: 10px;' class='thumbnail'/>
    <fieldset>
    <div class="control-group">
      <label class="control-label" for="badge_name">Badge name: </label>
      <div class="controls">
        <input type="text" class="span2" placeholder="name" id="badge_name" name="badge_name" value="#{CGI.escapeHTML(settings['badge_name'] || "")}"/>
      </div>
    </div>
    <div class="control-group">
      <label class="control-label" for="badge_url">Badge icon: </label>
      <div class="controls">
        <input type="text" class="span2" placeholder="http://" id="badge_url" name="badge_url" value="#{CGI.escapeHTML(settings['badge_url'] || "")}"/>
      </div>
    </div>
    <div class="control-group">
      <label class="control-label" for="badge_description">Badge description: </label>
      <div class="controls">
        <textarea class='input-xlarge' rows='3' name='badge_description' id='badge_description'>#{CGI.escapeHTML(settings['badge_description'] || "")}</textarea>
      </div>
    </div>
    <div class="control-group">
      <label class="control-label" for="min_percent">Final grade cutoff: </label>
      <div class="controls">
        <div class="input-append">
          <input type="text" class="span1" placeholder="##" id="min_percent" name="min_percent" value="#{settings['min_percent']}"/><span class='add-on'> % </span>
        </div>
      </div>
    </div>
    <div class="form-actions" style="border: 0; background: transparent;">
      <button type="submit" class='btn btn-primary'>Save Badge Settings</button>
    </div>
    </fieldset>
    </form> 
  HTML
end

def error(message)
  header + "<h2>" + message + "</h2>" + footer
end

def message(message)
  header + "<h2>" + message + "</h2>" + footer
end

def header
  <<-HTML
<html>
  <head>
    <meta charset="utf-8">
    <title>Canvabadges</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="">
    <meta name="author" content="">

    <!-- Le styles -->
    <link href="/bootstrap/css/bootstrap.css" rel="stylesheet">
    <link href="/bootstrap/css/bootstrap-responsive.css" rel="stylesheet">

    <!-- Le HTML5 shim, for IE6-8 support of HTML5 elements -->
    <!--[if lt IE 9]>
      <script src="http://html5shim.googlecode.com/svn/trunk/html5.js"></script>
    <![endif]-->

    <!-- Le fav and touch icons -->
    <link rel="shortcut icon" href="/bootstrap/ico/favicon.ico">
    <link rel="apple-touch-icon-precomposed" sizes="114x114" href="/bootstrap/ico/apple-touch-icon-114-precomposed.png">
    <link rel="apple-touch-icon-precomposed" sizes="72x72" href="/bootstrap/ico/apple-touch-icon-72-precomposed.png">
    <link rel="apple-touch-icon-precomposed" href="/bootstrap/ico/apple-touch-icon-57-precomposed.png">
    <style>
    .progress-big, .progress-big .bar {
      height: 40px;
    }
    .progress-big {
      width: 300px;
      position: relative;
    }
    .progress-big .tick {
      z-index: 2;
      width: 0px;
      border: 1px solid #000;
      height: 44px;
      top: -2px;
      position: absolute;
    }
    body {
      padding-top: 40px;
    }
    .earn_badge {
      cursor: pointer;
    }
    </style>
  </head>
  <body>
    <div class="container" id="content">
    <div id="contents">
  HTML
end

def footer
  <<-HTML
    </div>
  </div>
  <script src="/jquery.min.js"></script>
  <script src="http://beta.openbadges.org/issuer.js"></script>
  <script>
  $("#redeem").click(function() {
    OpenBadges.issue([$(this).attr('rel')]);
  });
  $(".earn_badge").live('click', function() {
    $(this).parent().find("form").css('visibility', 'visible');
  });
  </script>
</body>
</html>
  HTML
end

def config_wrap(xml)
  res = <<-XML
<?xml version="1.0" encoding="UTF-8"?>
  <cartridge_basiclti_link xmlns="http://www.imsglobal.org/xsd/imslticc_v1p0"
      xmlns:blti = "http://www.imsglobal.org/xsd/imsbasiclti_v1p0"
      xmlns:lticm ="http://www.imsglobal.org/xsd/imslticm_v1p0"
      xmlns:lticp ="http://www.imsglobal.org/xsd/imslticp_v1p0"
      xmlns:xsi = "http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation = "http://www.imsglobal.org/xsd/imslticc_v1p0 http://www.imsglobal.org/xsd/lti/ltiv1p0/imslticc_v1p0.xsd
      http://www.imsglobal.org/xsd/imsbasiclti_v1p0 http://www.imsglobal.org/xsd/lti/ltiv1p0/imsbasiclti_v1p0.xsd
      http://www.imsglobal.org/xsd/imslticm_v1p0 http://www.imsglobal.org/xsd/lti/ltiv1p0/imslticm_v1p0.xsd
      http://www.imsglobal.org/xsd/imslticp_v1p0 http://www.imsglobal.org/xsd/lti/ltiv1p0/imslticp_v1p0.xsd">
  XML
  res += xml
  res += <<-XML
      <cartridge_bundle identifierref="BLTI001_Bundle"/>
      <cartridge_icon identifierref="BLTI001_Icon"/>
  </cartridge_basiclti_link>  
  XML
end

get "/config.xml" do
  host = "https://" + request.host_with_port
  headers 'Content-Type' => 'text/xml'
  xml =  <<-XML
    <blti:title>Mozilla Open Badges</blti:title>
    <blti:description>Award open badges to students based on their course accomplishments</blti:description>
    <blti:launch_url>#{host}/badge_check</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="privacy_level">public</lticm:property>
  XML
  if params['course_nav']
    xml +=  <<-XML
      <lticm:options name="user_navigation">
        <lticm:property name="url">#{host}/badge_check</lticm:property>
        <lticm:property name="text">Badge</lticm:property>
      </lticm:options>
    XML
  end
  xml +=  <<-XML
    </blti:extensions>
  XML
  config_wrap(xml)
end
