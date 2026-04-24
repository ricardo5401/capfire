# frozen_string_literal: true

module CapfireCli
  # `bin/capfire token create|list|revoke` subcommands.
  class TokensCommand < Thor
    package_name 'capfire token'

    desc 'create', 'Create and sign a new API token'
    long_desc <<~DESC
      Creates a new JWT, stores its metadata in the `api_tokens` table and prints the token on stdout.

      The token is shown only once. Copy it immediately — Capfire does not store the JWT itself,
      only its metadata (jti, name, apps, envs, cmds).

      Examples:
        bin/capfire token create --name=ci-staging --apps=app-a,app-b --envs=staging --cmds=deploy,restart
        bin/capfire token create --name=admin --apps=* --envs=staging,production --cmds=deploy,restart,rollback,status
        bin/capfire token create --name=short-lived --apps=* --envs=staging --cmds=deploy --expires-in=24h
    DESC
    method_option :name, type: :string, required: true, desc: 'Human-readable token name'
    method_option :apps, type: :string, required: true, desc: 'Comma-separated app list, or "*"'
    method_option :envs, type: :string, required: true, desc: 'Comma-separated environments'
    method_option :cmds, type: :string, required: true, desc: 'Comma-separated commands'
    method_option :"expires-in", type: :string, required: false,
                                 desc: 'Expiry like "24h", "7d", "30d". Omit for non-expiring tokens.'
    def create
      apps = parse_list(options[:apps])
      envs = parse_list(options[:envs])
      cmds = parse_list(options[:cmds])
      expires_at = parse_expiry(options[:"expires-in"])

      jti = SecureRandom.uuid
      issued_at = Time.current

      token, claims = JwtService.encode(
        name: options[:name],
        apps: apps,
        envs: envs,
        cmds: cmds,
        expires_at: expires_at,
        jti: jti,
        issued_at: issued_at
      )

      ApiToken.create!(
        jti: jti,
        name: options[:name],
        apps: apps,
        envs: envs,
        cmds: cmds,
        issued_at: issued_at,
        expires_at: expires_at
      )

      puts 'Token created. Copy it now — it will not be shown again.'
      puts
      puts "  jti:     #{claims[:jti]}"
      puts "  name:    #{claims[:sub]}"
      puts "  apps:    #{claims[:apps].join(', ')}"
      puts "  envs:    #{claims[:envs].join(', ')}"
      puts "  cmds:    #{claims[:cmds].join(', ')}"
      puts "  expires: #{expires_at ? expires_at.iso8601 : 'never'}"
      puts
      puts token
    end

    desc 'list', 'List tokens known to this Capfire instance'
    def list
      tokens = ApiToken.order(created_at: :desc)
      if tokens.empty?
        puts '(no tokens)'
        return
      end

      tokens.each do |t|
        state = t.revoked? ? 'REVOKED' : 'active'
        expires = t.expires_at ? t.expires_at.iso8601 : 'never'
        puts "##{t.id}  #{state.ljust(8)}  #{t.name}"
        puts "    jti:     #{t.jti}"
        puts "    apps:    #{t.apps.join(', ')}"
        puts "    envs:    #{t.envs.join(', ')}"
        puts "    cmds:    #{t.cmds.join(', ')}"
        puts "    issued:  #{t.issued_at&.iso8601}"
        puts "    expires: #{expires}"
        puts "    revoked: #{t.revoked_at&.iso8601}" if t.revoked?
        puts
      end
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
      raise ArgumentError, "invalid --expires-in format: #{raw}" unless match

      value = match[1].to_i
      unit_seconds = { 's' => 1, 'm' => 60, 'h' => 3600, 'd' => 86_400 }.fetch(match[2])
      Time.current + (value * unit_seconds)
    end
  end
end
