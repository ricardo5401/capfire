# frozen_string_literal: true

module CapfireCli
  # `bin/capfire tokens create|list|revoke` subcommands.
  class TokensCommand < Thor
    package_name 'capfire tokens'

    desc 'create', 'Create and sign a new API token'
    long_desc <<~DESC
      Creates a new JWT, stores its metadata in the `api_tokens` table and prints
      the token on stdout. The token is shown ONLY ONCE — copy it immediately.

      PER-APP GRANTS (recommended for teams):
      Pass --grant one or more times. Format is APP:ENVS:CMDS with commas for
      lists inside each field and `*` as the wildcard.

        bin/capfire tokens create --name=juan \\
          --grant='myapp-api:staging,production:deploy,restart' \\
          --grant='myapp:staging:deploy,restart'

      Admin token (everything):
        bin/capfire tokens create --name=admin --grant='*:*:*'

      LEGACY FLAGS (cartesian product — still supported):
        bin/capfire tokens create --name=ci --apps=myapp --envs=staging --cmds=deploy
    DESC
    method_option :name, type: :string, required: true, desc: 'Human-readable token name'
    method_option :grant, type: :string, repeatable: true, required: false,
                          desc: 'Grant in APP:ENVS:CMDS form (comma-separated inside each field). Repeatable.'
    method_option :apps, type: :string, required: false, desc: 'Legacy: comma-separated app list, or "*"'
    method_option :envs, type: :string, required: false, desc: 'Legacy: comma-separated environments'
    method_option :cmds, type: :string, required: false, desc: 'Legacy: comma-separated commands'
    method_option :"expires-in", type: :string, required: false,
                                 desc: 'Expiry like "24h", "7d". Omit for non-expiring tokens.'
    def create
      grants = build_grants_from_options
      expires_at = parse_expiry(options[:"expires-in"])

      jti = SecureRandom.uuid
      issued_at = Time.current

      token, claims = JwtService.encode(
        name: options[:name],
        grants: grants,
        expires_at: expires_at,
        jti: jti,
        issued_at: issued_at
      )

      persist_token!(jti: jti, name: options[:name], grants: grants,
                     issued_at: issued_at, expires_at: expires_at)

      print_new_token(claims: claims, token: token, expires_at: expires_at)
    end

    desc 'list', 'List tokens known to this Capfire instance'
    def list
      tokens = ApiToken.order(created_at: :desc)
      if tokens.empty?
        puts '(no tokens)'
        return
      end

      tokens.each { |t| print_token_summary(t) }
    end

    desc 'revoke TOKEN_ID', 'Revoke a token by numeric id or jti'
    method_option :reason, type: :string, required: false
    def revoke(token_id)
      token = find_token(token_id)
      unless token
        warn "token not found: #{token_id}"
        exit 1
      end

      if token.revoked?
        puts "token already revoked at #{token.revoked_at.iso8601}"
        return
      end

      token.revoke!(reason: options[:reason])
      puts "revoked token ##{token.id} (#{token.name})"
    end

    private

    # Turns CLI options into the grants array accepted by JwtService.encode.
    # Prefers --grant if present; otherwise falls back to the legacy trio.
    # Rejects the call when neither is provided.
    def build_grants_from_options
      raw_grants = Array(options[:grant])
      if raw_grants.any?
        validate_legacy_not_mixed!
        return raw_grants.map { |g| parse_grant_spec(g) }
      end

      legacy_to_grants(apps: options[:apps], envs: options[:envs], cmds: options[:cmds])
    end

    def validate_legacy_not_mixed!
      return if options[:apps].blank? && options[:envs].blank? && options[:cmds].blank?

      raise Thor::Error, 'pass EITHER --grant (new shape) OR --apps/--envs/--cmds (legacy); not both'
    end

    # Parses "APP:ENVS_CSV:CMDS_CSV" into { app, envs, cmds }.
    def parse_grant_spec(spec)
      parts = spec.to_s.split(':', 3)
      unless parts.length == 3
        raise Thor::Error, "invalid --grant '#{spec}' (expected APP:ENVS:CMDS)"
      end

      app, envs, cmds = parts
      {
        app: app.strip,
        envs: parse_list(envs),
        cmds: parse_list(cmds)
      }
    end

    def legacy_to_grants(apps:, envs:, cmds:)
      [ apps, envs, cmds ].each do |v|
        raise Thor::Error, 'missing permissions — use --grant or --apps/--envs/--cmds' if v.to_s.strip.empty?
      end

      parse_list(apps).map do |app|
        { app: app, envs: parse_list(envs), cmds: parse_list(cmds) }
      end
    end

    def persist_token!(jti:, name:, grants:, issued_at:, expires_at:)
      # Populate the legacy columns with flattened values for readable SQL
      # dumps and for old callers that still query them directly.
      flat_apps = grants.map { |g| g[:app] }.uniq
      flat_envs = grants.flat_map { |g| g[:envs] }.uniq
      flat_cmds = grants.flat_map { |g| g[:cmds] }.uniq

      ApiToken.create!(
        jti: jti,
        name: name,
        grants: grants.map { |g| g.transform_keys(&:to_s) },
        apps: flat_apps,
        envs: flat_envs,
        cmds: flat_cmds,
        issued_at: issued_at,
        expires_at: expires_at
      )
    end

    def print_new_token(claims:, token:, expires_at:)
      puts 'Token created. Copy it now — it will not be shown again.'
      puts
      puts "  jti:     #{claims[:jti]}"
      puts "  name:    #{claims[:sub]}"
      puts "  expires: #{expires_at ? expires_at.iso8601 : 'never'}"
      puts '  grants:'
      Array(claims[:grants]).each do |g|
        puts "    #{format_grant(g)}"
      end
      puts
      puts token
    end

    def print_token_summary(token)
      state = token.revoked? ? 'REVOKED' : 'active'
      expires = token.expires_at ? token.expires_at.iso8601 : 'never'
      puts "##{token.id}  #{state.ljust(8)}  #{token.name}"
      puts "    jti:     #{token.jti}"
      puts "    issued:  #{token.issued_at&.iso8601}"
      puts "    expires: #{expires}"
      puts "    revoked: #{token.revoked_at&.iso8601}" if token.revoked?
      puts '    grants:'
      token.grants_list.each { |g| puts "      #{format_grant(g)}" }
      puts
    end

    def format_grant(grant)
      hash = grant.respond_to?(:with_indifferent_access) ? grant.with_indifferent_access : grant
      app  = hash['app']
      envs = Array(hash['envs']).join(',')
      cmds = Array(hash['cmds']).join(',')
      "app=#{app}  envs=#{envs}  cmds=#{cmds}"
    end

    def find_token(identifier)
      if identifier.match?(/\A\d+\z/)
        ApiToken.find_by(id: identifier.to_i)
      else
        ApiToken.find_by(jti: identifier)
      end
    end

    def parse_list(raw)
      Array(raw.to_s.split(',')).map(&:strip).reject(&:empty?)
    end

    def parse_expiry(raw)
      return nil if raw.blank?

      match = raw.strip.match(/\A(\d+)([smhd])\z/)
      raise Thor::Error, "invalid --expires-in format: #{raw}" unless match

      value = match[1].to_i
      unit_seconds = { 's' => 1, 'm' => 60, 'h' => 3600, 'd' => 86_400 }.fetch(match[2])
      Time.current + (value * unit_seconds)
    end
  end
end
