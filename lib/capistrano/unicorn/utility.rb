require 'tempfile'

module CapistranoUnicorn
  module Utility
    # In Capistrano 3, shell scripts must be invoked with SSHKit's execute, instead of run.
    # SSHKit will "sanitize" all multi-line commands (here docs), replacing "\n" with ";".
    # Sanitizing renders some shell scripts illegal, for instance:
    #
    #   if [ -e FILE ]; then
    #     echo "Found."
    #   fi
    # 
    # This would become
    #
    #   if [ -e FILE ]; then; echo "Found."; fi;
    #
    # which is illegal because of the ';' after 'then'.
    #
    # To avoid errors, replace all "\n" with " " in shell scripts,
    # before SSHKit gets a chance to replace "\n" with ";"
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
      "[ -e #{pid_file} ] && #{unicorn_send_signal(0, get_unicorn_pid(pid_file))} > /dev/null 2>&1"
    end

    # Stale Unicorn process pid file
    #
    def old_unicorn_pid
      "#{fetch :unicorn_pid}.oldbin"
    end

    # Command to check if Unicorn is running
    #
    def unicorn_is_running?
      remote_process_exists?(fetch :unicorn_pid)
    end

    # Command to check if stale Unicorn is running
    #
    def old_unicorn_is_running?
      remote_process_exists?(old_unicorn_pid)
    end

    # Get unicorn master process PID (using the shell)
    #
    def get_unicorn_pid(pid_file=fetch(:unicorn_pid))
      "`cat #{pid_file}`"
    end

    # Get unicorn master (old) process PID
    #
    def get_old_unicorn_pid
      get_unicorn_pid(old_unicorn_pid)
    end

    # Send a signal to a unicorn master processes
    #
    def unicorn_send_signal(signal, pid=get_unicorn_pid)
      sig_prefix = Integer === signal ? '-' : '-s '
      "#{try_unicorn_user} kill #{sig_prefix}#{signal} #{pid}"
    end

    # Run a command as the :unicorn_user user if :unicorn_user is a string.
    # Otherwise run as default (:user) user.
    #
    def try_unicorn_user
      "#{sudo :as => unicorn_user.to_s}" if fetch(:unicorn_user).kind_of?(String)
    end

    # Kill Unicorns in multiple ways O_O
    #
    def kill_unicorn(signal)
      script = <<-END
        if #{unicorn_is_running?}; then
          echo "Stopping Unicorn...";
          #{unicorn_send_signal(signal)};
        else
          echo "Unicorn is not running.";
        fi;
      END
      script.split.join(' ')
    end

    # Start the Unicorn server
    #
    def start_unicorn
      %Q%
        if [ -e "#{fetch :unicorn_config_file_path}" ]; then
          UNICORN_CONFIG_PATH=#{fetch :unicorn_config_file_path};
        else
          if [ -e "#{fetch :unicorn_config_stage_file_path}" ]; then
            UNICORN_CONFIG_PATH=#{fetch :unicorn_config_stage_file_path};
          else
            echo "Config file for "#{fetch :unicorn_env}" environment was not found at either "#{fetch :unicorn_config_file_path}" or "#{fetch :unicorn_config_stage_file_path}"";
            exit 1;
          fi;
        fi;

        if [ -e "#{fetch :unicorn_pid}" ]; then
          if #{try_unicorn_user} kill -0 `cat #{fetch :unicorn_pid}` > /dev/null 2>&1; then
            echo "Unicorn is already running!";
            exit 0;
          fi;

          #{try_unicorn_user} rm #{fetch :unicorn_pid};
        fi;

        echo "Starting Unicorn...";
        cd #{fetch :app_path} && #{try_unicorn_user} RAILS_ENV=#{fetch :rails_env} BUNDLE_GEMFILE=#{fetch :bundle_gemfile} #{fetch :unicorn_bundle} exec #{fetch :unicorn_bin} -c $UNICORN_CONFIG_PATH -E #{fetch :unicorn_rack_env} -D #{fetch :unicorn_options};
      %.split.join(' ')
    end

    def duplicate_unicorn
      script = <<-END
        if #{unicorn_is_running?}; then
          echo "Duplicating Unicorn...";
          #{unicorn_send_signal('USR2')};
        else
          #{start_unicorn}
        fi;
      END
      script.split.join(' ')
    end

    def unicorn_roles
      # TODO proc necessary here?
      Proc.new{ fetch(:unicorn_roles, :app) }.call
      #defer{ fetch(:unicorn_roles, :app) }
    end

  end
end
