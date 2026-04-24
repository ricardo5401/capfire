# frozen_string_literal: true

require 'open3'
require 'shellwords'

module CapfireCli
  # `bin/capfire project add|list` — manage the apps this Capfire node can
  # deploy. An "app" is simply a git checkout inside `$APPS_ROOT/<name>` with
  # (optionally) a `capfire.yml` at its root. Capfire itself does not own the
  # repo lifecycle — we just clone it for you and print the next steps.
  class ProjectCommand < Thor
    package_name 'capfire project'

    desc 'add URL', 'Clone a git repository into the Capfire apps root'
    long_desc <<~DESC
      Clones a git repository into `$CAPFIRE_APPS_ROOT/<name>` so this node
      can deploy it. Does NOT run bundler / yarn / capistrano — only the git
      clone. Configure the rest via the app's `capfire.yml`.

      By default `<name>` is derived from the URL (`myapp` from
      `git@github.com:myorg/myapp.git`). Override with `--name`.

      Examples:
        bin/capfire project add git@github.com:myorg/myapp.git
        bin/capfire project add https://github.com/myorg/myapp.git --name=myapp
        bin/capfire project add git@github.com:myorg/myapp.git --branch=production
    DESC
    method_option :name,   type: :string, required: false, desc: 'Override the directory name under apps_root'
    method_option :branch, type: :string, required: false, desc: 'Initial branch to check out (default: origin HEAD)'
    NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}\z/

    def add(url)
      name = options[:name].presence || derive_name(url)
      raise Thor::Error, "could not derive a name from URL: #{url}" if name.blank?
      unless name.match?(NAME_PATTERN)
        raise Thor::Error, "invalid app name '#{name}': must match #{NAME_PATTERN.source}"
      end

      target = File.join(apps_root, name)

      if File.exist?(target)
        say_status(:exists, target, :yellow)
        puts 'Directory already exists — skipping clone. Remove it first if you want to re-clone.'
        return
      end

      FileUtils.mkdir_p(apps_root)
      say_status(:clone, "#{url} -> #{target}", :green)

      git_clone!(url: url, target: target, branch: options[:branch])

      print_next_steps(name: name, target: target)
    end

    desc 'list', 'List apps registered under CAPFIRE_APPS_ROOT'
    def list
      unless File.directory?(apps_root)
        puts "(apps_root does not exist yet: #{apps_root})"
        return
      end

      entries = Dir.children(apps_root).sort.select { |e| File.directory?(File.join(apps_root, e)) }
      if entries.empty?
        puts "(no apps in #{apps_root})"
        return
      end

      entries.each do |name|
        path = File.join(apps_root, name)
        yml = File.exist?(File.join(path, 'capfire.yml')) ? 'capfire.yml' : '-'
        puts "  #{name.ljust(30)} #{path.ljust(40)} #{yml}"
      end
    end

    private

    def apps_root
      Capfire.config.apps_root
    end

    # `git@github.com:myorg/myapp.git`    -> myapp
    # `https://github.com/myorg/myapp.git` -> myapp
    # `https://github.com/myorg/myapp`     -> myapp
    def derive_name(url)
      tail = url.to_s.split('/').last.to_s
      tail.sub(/\.git\z/, '').strip
    end

    def git_clone!(url:, target:, branch: nil)
      # `--` separates flags from positional args so a malicious URL starting
      # with `-` cannot be interpreted as a git option.
      cmd = [ 'git', 'clone' ]
      cmd += [ '--branch', branch ] if branch.present?
      cmd += [ '--', url, target ]

      stdout_err, status = Open3.capture2e(*cmd)
      return if status.success?

      raise Thor::Error, "git clone failed (exit #{status.exitstatus}):\n#{stdout_err}"
    end

    def print_next_steps(name:, target:)
      puts
      puts "Project '#{name}' cloned to #{target}."
      puts 'Next steps:'
      puts "  1. cd #{target}"
      puts '  2. Create capfire.yml if you need custom deploy/restart commands.'
      puts '  3. Configure Capistrano (or whatever tool deploys this app) to reach the remote hosts.'
      puts "  4. Create a token allowlisted for this app:  bin/capfire tokens create --apps=#{name} ..."
      puts
    end
  end
end
