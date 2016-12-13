# name: discourse-oidc-basic
# about: Generic OpenID Connect Plugin
# version: 0.1
# authors: Michał "rysiek" Woźniak <rysiek@occrp.org>

enabled_site_setting :oidc_enabled

#
# reading materials:
# https://meta.discourse.org/t/beginners-guide-to-creating-discourse-plugins/30515
# https://github.com/omniauth/omniauth/wiki/managing-multiple-providers
# http://www.rubydoc.info/github/discourse/discourse/Discourse
#

class ::OmniAuth::Strategies::OpenIDConnectWithRoles < ::OmniAuth::Strategies::OpenIDConnect
    option :name, "openid_connect_with_roles"
#     info do
#         {
#             id: access_token['id']
#         }
#     end
    extra do
        {
            raw_attributes: decode_id_token(access_token.access_token).raw_attributes
        }
    end
    
end
OmniAuth.config.add_camelization 'openid_connect_with_roles', 'OpenIDConnectWithRoles'


# based on:
# https://github.com/discourse/discourse/blob/master/lib/auth/open_id_authenticator.rb
# original code on GNU GPL v.2
class OpenIdConnectAuthenticator < Auth::Authenticator

    attr_reader :identifier

    def name
        'openid_connect'
    end

    def initialize(identifier, opts = {})
        #@name = name
        @identifier = identifier
        @opts = opts
    end

    def after_authenticate(auth_token)
        
        Rails.logger.debug "OpenIdConnectAuthenticator :: after_authenticate"
        
        result = Auth::Result.new

        data = auth_token[:info]
        identity_url = auth_token[:extra][:response].identity_url
        result.email = email = data[:email]

        raise Discourse::InvalidParameters.new(:email) if email.blank?

        # If the auth supplies a name / username, use those. Otherwise start with email.
        result.name = data[:name] || data[:email]
        result.username = data[:nickname] || data[:email]

        user_open_id = UserOpenId.find_by_url(identity_url)

        if !user_open_id && @opts[:trusted] && user = User.find_by_email(email)
            user_open_id = UserOpenId.create(url: identity_url , user_id: user.id, email: email, active: true)
        end

        result.user = user_open_id.try(:user)
        result.extra_data = {
            openid_url: identity_url,
            # note email may change by the time after_create_account runs
            email: email
        }
        
        # groups?

        result.email_valid = @opts[:trusted]

        result
    end

    def after_create_account(user, auth)
        
        Rails.logger.debug "OpenIdConnectAuthenticator :: after_create_account"
        
        data = auth[:extra_data]
        UserOpenId.create(
            user_id: user.id,
            url: data[:openid_url],
            email: data[:email],
            active: true
            # groups?
        )
    end


    def register_middleware(omniauth)
        
        Rails.logger.debug "OpenIdConnectAuthenticator :: register_middleware"
        
#         omniauth.provider :openid_connect,
#                       :setup => lambda { |env|
#                             strategy = env["omniauth.strategy"]
#                             strategy.options[:store] = OpenID::Store::Redis.new($redis)
#                       },
#                       :name => name,
#                       :identifier => identifier,
#                       :require => "omniauth-openid-connect"

        omniauth.provider :openid_connect_with_roles,
            name: "openid_connect",
            identifier: "openid_connect",
            setup:   -> (env) {
                env["omniauth.strategy"].options.merge!(
                scope: [:openid, :email, :profile, :address],
                response_type: :code,
                discovery: true,
                issuer: SiteSetting.oidc_issuer_url,
                client_options: {
                    port: 443,
                    scheme: "https",
                    host: SiteSetting.oidc_issuer_host,
                    identifier: SiteSetting.oidc_client_id,
                    secret: SiteSetting.oidc_client_secret,
                    redirect_uri: 'https://' + Discourse.current_hostname + Discourse.base_uri + "/auth/openid_connect/callback"
                })
            }
            
        Rails.logger.debug "OpenIdConnectAuthenticator :: register_middleware :: done!"
    end
    
    #def basic_auth_header
    #    "Basic " + Base64.strict_encode64("#{SiteSetting.oidc_client_id}:#{SiteSetting.oidc_client_secret}")
    #end

    def walk_path(fragment, segments)
        
        Rails.logger.debug "OpenIdConnectAuthenticator :: walk_path"
        Rails.logger.debug "OpenIdConnectAuthenticator :: walk_path :: segments: " + segments.inspect
        
        first_seg = segments[0]
        Rails.logger.debug "OpenIdConnectAuthenticator :: walk_path :: first_seg: " + first_seg.inspect
        return if first_seg.blank? || fragment.blank?
        return nil unless fragment.is_a?(Hash)
        
        # is this a setting we're referencing?
        if first_seg[0] == ':'
            # aye, clean it up
            first_seg.slice! ':'
            # get it from SiteSettings
            first_seg = SiteSetting.send("oidc_#{first_seg}")
        end
        
        deref = fragment[first_seg] || fragment[first_seg.to_sym]
        Rails.logger.debug "OpenIdConnectAuthenticator :: walk_path :: deref: " + deref.inspect

        return (deref.blank? || segments.size == 1) ? deref : walk_path(deref, segments[1..-1])
    end

    def json_walk(result, user_json, prop)
        
        Rails.logger.debug "OpenIdConnectAuthenticator :: json_walk"
        
        path = SiteSetting.send("oidc_json_#{prop}_path")
        Rails.logger.debug "OpenIdConnectAuthenticator :: json_walk :: prop: " + prop.inspect
        Rails.logger.debug "OpenIdConnectAuthenticator :: json_walk :: path: " + path.inspect
        
        if path.present?
            segments = path.split('.')
            val = walk_path(user_json, segments)
            if val.present?
                result[prop] = val 
                # return true if we've found the property in the data
                # and the property contains any actual data
                true
            # otherwise return false
            else
                false
            end
        # otherwise return false
        else
            false
        end
    end

    def log(info)
        Rails.logger.warn("OIDC Debugging: #{info}") if SiteSetting.oidc_debug_auth
    end

    def fetch_user_details(token, id, raw_attributes)
        
        Rails.logger.debug "OpenIdConnectAuthenticator :: fetch_user_details"
        
        # attempt getting all the details from extra.raw_attributes
        # we should already have these anyway, so that would save us the round trip
        # and at the same time the raw_attributes are gotten from the access_token
        # which is signed by the server and (should be) verified by the OIDC provider
        # 
        # this, of course, assumes access_token and userinfo have the same data for the same keys
        # (if the same key exists in both)... so, caveat emptor!
        
        result = {}
        props = [ :user_id, :username, :name, :email, :groups ]
        
        Rails.logger.debug "OpenIdConnectAuthenticator :: fetch_user_details :: raw_attributes"
        props.dup.each do |prop|
            if json_walk(result, raw_attributes, prop)
                Rails.logger.debug "OpenIdConnectAuthenticator :: fetch_user_details :: raw_attributes :: " + prop.inspect + " found"
                props.delete_at(props.index(prop))
            else
                Rails.logger.debug "OpenIdConnectAuthenticator :: fetch_user_details :: raw_attributes :: " + prop.inspect + " not found"
            end
        end
        
        # if props array is empty, we're done here
        if props.empty?
            Rails.logger.debug "OpenIdConnectAuthenticator :: fetch_user_details :: props empty, we're done"
            return result
        end
        
        # ok, we need to do the round trip
        Rails.logger.debug "OpenIdConnectAuthenticator :: fetch_user_details :: user_info"
        user_json_url = SiteSetting.oidc_user_json_url.sub(':token', token.to_s).sub(':id', id.to_s)

        log("user_json_url: #{user_json_url}")
        Rails.logger.debug "OpenIdConnectAuthenticator :: fetch_user_details :: user_info :: fetching"
        user_json = JSON.parse(open(user_json_url, 'Authorization' => "Bearer #{token}" ).read)

        log("user_json: #{user_json}")
        
        # did we get anything?
        if user_json.present?
            Rails.logger.debug "OpenIdConnectAuthenticator :: fetch_user_details :: user_info :: user_json non-empty"
            props.dup.each do |prop|
                if json_walk(result, user_json, prop)
                    Rails.logger.debug "OpenIdConnectAuthenticator :: fetch_user_details :: user_info :: " + prop.inspect + " found"
                    props.delete_at(props.index(prop))
                else
                    Rails.logger.debug "OpenIdConnectAuthenticator :: fetch_user_details :: user_info :: " + prop.inspect + " not found"
                end
            end
        end
        
        # props array should be empty now, let's make sure
        if not props.empty?
            Rails.logger.debug "OpenIdConnectAuthenticator :: fetch_user_details :: props still not empty: " + props.inspect
        end

        result
    end

    def after_authenticate(auth)
        log("after_authenticate response: \n\ncreds: #{auth['credentials'].to_hash}\ninfo: #{auth['info'].to_hash}\nextra: #{auth['extra'].to_hash}")

        Rails.logger.debug "OpenIdConnectAuthenticator :: after_authenticate"
        
        result = Auth::Result.new
        token = auth['credentials']['token']
        user_details = fetch_user_details(token, auth['info'][:id], auth['extra']['raw_attributes'])

        result.name = user_details[:name]
        result.username = user_details[:username]
        result.email = user_details[:email]
        result.email_valid = result.email.present? && SiteSetting.oidc_email_verified?

        current_info = ::PluginStore.get("openid_connect", "oidc_basic_user_#{user_details[:user_id]}")
        if current_info
            result.user = User.where(id: current_info[:user_id]).first
        elsif SiteSetting.oidc_email_verified?
            result.user = User.where(email: Email.downcase(result.email)).first
            if result.user && user_details[:user_id]
                ::PluginStore.set("openid_connect", "oidc_basic_user_#{user_details[:user_id]}", {user_id: result.user.id})
            end
        end

        result.extra_data = { oidc_basic_user_id: user_details[:user_id] }
        result
    end

    def after_create_account(user, auth)
        
        Rails.logger.debug "OpenIdConnectAuthenticator :: after_create_account"
        
        ::PluginStore.set("openid_connect", "oidc_basic_user_#{auth[:extra_data][:oidc_basic_user_id]}", {user_id: user.id })
    end
end

auth_provider title: "OpenID Connect",
                title_setting: "oidc_button_title",
                message: "OpenID Connect",
                message_setting: "oidc_button_message",
                background_color: "#f8931d",
                enabled_setting: "oidc_enabled",
                authenticator: OpenIdConnectAuthenticator.new('openid_connect'),
                frame_width: 920,
                frame_height: 800

#raise aproviders.inspect + "\n\n\n" + aproviders.instance_variable_get(:@authenticator).inspect

register_css <<CSS

    button.btn-social.openid_connect {
        background-color: #f8931d;
    }

CSS
