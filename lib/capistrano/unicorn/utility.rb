require 'tempfile'

module CapistranoUnicorn
  module Utility
    # In Capistrano 3, shell scripts must be invoked with SSHKit's execute, instead of run.
    def local_unicorn_config
      if File.exist? fetch(:unicorn_config_rel_file_path)
        fetch(:unicorn_config_rel_file_path)
      else
        fetch(:unicorn_config_stage_rel_file_path)
      end
    end

    def extract_pid_file
      tmp = Tempfile.new('unicorn.rb')
      begin
        conf = local_unicorn_config
        tmp.write <<-EOF.gsub(/^ */, '')
          config_file = "#{conf}"

          # stub working_directory to avoid chdir failure since this will
          # run client-side:
          def working_directory(path); end

          instance_eval(File.read(config_file), config_file) if config_file
          puts set[:pid]
          exit 0
        EOF
        tmp.close
        extracted_pid = `unicorn -c "#{tmp.path}"`
        $?.success? ? extracted_pid.rstrip : nil
      rescue StandardError => e
        return nil
      ensure
        tmp.close
        tmp.unlink
      end
    end

    # Check if a remote process exists using its pid file
    #
    def remote_process_exists?(pid_file)
      test("[ -e #{pid_file} ]") && test("#{try_unicorn_user} kill -0 `cat #{pid_file}` > /dev/null 2>&1")
    end

    # Stale Unicorn process pid file
    #
    def old_unicorn_pid
      "#{fetch :unicorn_pid}.oldbin"
    end

    # Command to check if Unicorn is running
    #
    def unicorn_is_running?
      remote_process_exists?(fetch(:unicorn_pid))
    end

    # Command to check if stale Unicorn is running
    #
    def old_unicorn_is_running?
      remote_process_exists?(old_unicorn_pid)
    end

    # Get unicorn master process PID (using the shell)
    #
    def get_unicorn_pid(pid_file=fetch(:unicorn_pid))
      capture "cat #{pid_file}"
    end

    # Get unicorn master (old) process PID
    #
    def get_old_unicorn_pid
      get_unicorn_pid(old_unicorn_pid)
    end

    # Send a signal to a unicorn master processes
    #
    def unicorn_send_signal(signal, pid=get_unicorn_pid)
      execute try_unicorn_user, 'kill', '-s', signal, pid
    end

    # Run a command as the :unicorn_user user if :unicorn_user is a string.
    # Otherwise run as default (:user) user.
    #
    def try_unicorn_user
      if unicorn_user = fetch(:unicorn_user)
        "sudo -u #{unicorn_user}"
      else
        ''
      end
    end

    # Kill Unicorns in multiple ways O_O
    #
    def kill_unicorn(signal)
      if unicorn_is_running?
        puts 'Stopping unicorn...'
        unicorn_send_signal(signal)
      else
        puts 'Unicorn is not running'
      end
    end

    # Start the Unicorn server
    #
    def start_unicorn
      if test("[ -e #{fetch(:unicorn_config_file_path)} ]")
        unicorn_config_file_path = fetch(:unicorn_config_file_path)
      elsif test("[ -e #{fetch(:unicorn_config_stage_file_path)} ]")
        unicorn_config_file_path = fetch(:unicorn_config_stage_file_path)
      else
        fail "Config file for \"#{fetch(:unicorn_env)}\" environment was not found at either \"#{fetch(:unicorn_config_file_path)}\" or \"#{fetch(:unicorn_config_stage_file_path)}\""
      end

      if test("[ -e #{fetch(:unicorn_pid)} ]")
        if unicorn_is_running?
          puts 'Unicorn is already running!'
          return
        else
          execute :rm, fetch(:unicorn_pid)
        end
      end

      puts 'Starting unicorn...'

      within fetch(:app_path) do
        with rails_env: fetch(:rails_env), bundle_gemfile: fetch(:bundle_gemfile) do
          execute :bundle, 'exec', fetch(:unicorn_bin), '-c', unicorn_config_file_path, '-E', fetch(:unicorn_rack_env), '-D', fetch(:unicorn_options)
        end
      end
    end

    def duplicate_unicorn
      if unicorn_is_running?
        unicorn_send_signal('USR2')
      else
        start_unicorn
      end
    end

    def unicorn_roles
      # TODO proc necessary here?
      Proc.new{ fetch(:unicorn_roles, :app) }.call
      #defer{ fetch(:unicorn_roles, :app) }
    end
  end
end
