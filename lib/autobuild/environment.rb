require 'set'
require 'rbconfig'

module Autobuild
    @inherited_environment = Hash.new
    @environment = Hash.new
    @env_source_before = Set.new
    @env_source_after = Set.new

    @windows = RbConfig::CONFIG["host_os"] =~%r!(msdos|mswin|djgpp|mingw|[Ww]indows)!
    def self.windows?
        @windows
    end

    @macos =  RbConfig::CONFIG["host_os"] =~%r!([Dd]arwin)!
    def self.macos?
        @macos
    end

    SYSTEM_ENV = Hash.new
    ORIGINAL_ENV = Hash.new
    ENV.each do |k, v|
        ORIGINAL_ENV[k] = v
    end
    ENV_LIST_SEPARATOR =
        if windows? then ';'
        else ':'
        end
    SHELL_VAR_EXPANSION =
        if windows? then "%%%s%%"
        else "$%s"
        end
    SHELL_SET_COMMAND =
        if windows? then "set %s=%s"
        else "%s=%s"
        end
    SHELL_UNSET_COMMAND =
        if windows? then "unset %s"
        else "unset %s"
        end
    SHELL_EXPORT_COMMAND =
        if windows? then "set %s"
        else "export %s"
        end
    SHELL_SOURCE_SCRIPT =
        if windows? then "%s"
        else ". \"%s\""
        end
	
    class << self
        # List of the environment that should be set before calling a subcommand
        #
        # It is a map from environment variable name to the corresponding value.
        # If the value is an array, it is joined using the path separator ':'
        attr_reader :environment

        # In generated environment update shell files, indicates whether an
        # environment variable should be overriden by the shell script, or
        # simply updated
        #
        # If inherited_environment[varname] is true, the generated shell script
        # will contain
        #   
        #   export VARNAME=new_value:new_value:$VARNAME
        #
        # otherwise
        #
        #   export VARNAME=new_value:new_value
        attr_reader :inherited_environment

        # List of files that should be sourced in the generated environment
        # variable setting shell scripts
        attr_reader :env_source_before

        # List of files that should be sourced in the generated environment
        # variable setting shell scripts
        attr_reader :env_source_after
    end

    # Resets the value of +name+ to its original value. If it is inherited from
    # the 
    def self.env_reset(name = nil)
        if name
            environment.delete(name)
            inherited_environment.delete(name)
            env_init_from_env(name)
        else
            environment.keys.each do |name|
                env_reset(name)
            end
        end
    end

    # Unsets any value on the environment variable +name+, including inherited
    # value.
    #
    # In a bourne shell, this would be equivalent to doing
    #   
    #   unset name
    #
    def self.env_clear(name = nil)
        if name
            environment[name] = nil
            inherited_environment[name] = nil
            env_update_var(name)
        else
            environment.keys.each do |name|
                env_clear(name)
            end
        end
    end

    # Set a new environment variable
    def self.env_set(name, *values)
        env_reset(name)
        env_add(name, *values)
    end

    @env_inherit = true
    @env_inherited_variables = Set.new

    # Returns true if the given environment variable must not be reset by the
    # env.sh script, but that new values should simply be prepended to it.
    #
    # @param [String,nil] name the environment variable that we want to check
    #   for inheritance. If nil, the global setting is returned.
    #
    # @see env_inherit env_inherit=
    def self.env_inherit?(name = nil)
        if @env_inherit
            if name 
                @env_inherited_variables.include?(name)
            else true
            end
        end
    end

    # If true (the default), the environment variables that are marked as
    # inherited will be inherited from the global environment (during the
    # build as well as in the generated env.sh files)
    #
    # Otherwise, only the environment that is explicitely set in autobuild
    # will be passed on to subcommands, and saved in the environment
    # scripts.
    #
    # @see env_inherit? env_inherit
    def self.env_inherit=(value)
        @env_inherit = value
        inherited_environment.keys.each do |env_name|
            env_init_from_env(env_name)
        end
    end

    # Declare that the given environment variable must not be reset by the
    # env.sh script, but that new values should simply be prepended to it.
    #
    # @return [Boolean] true if environment inheritance is globally enabled and
    #   false otherwise. This is controlled by {env_inherit=}
    #
    # @see env_inherit? env_inherit=
    def self.env_inherit(*names)
        @env_inherited_variables |= names
        names.each do |env_name|
            env_init_from_env(env_name)
        end
        @env_inherit
    end

    def self.env_init_from_env(name)
        if env_inherit?(name) && (parent_env = ORIGINAL_ENV[name])
            inherited_environment[name] = parent_env.split(ENV_LIST_SEPARATOR)
        else
            inherited_environment[name] = Array.new
        end
        env_update_var(name)
    end

    def self.env_push(name, *values)
        if current = environment[name]
            current = current.dup
            env_set(name, *values)
            env_add(name, *current)
        else
            env_add(name, *values)
        end
    end

    # Adds a new value to an environment variable
    def self.env_add(name, *values)
        set = if environment.has_key?(name)
                  environment[name]
              end

        if !inherited_environment.has_key?(name)
            env_init_from_env(name)
        end

        if !set
            set = Array.new
        elsif !set.respond_to?(:to_ary)
            set = [set]
        end

        values.concat(set)
        @environment[name] = values
        env_update_var(name)
    end

    def self.env_value(name, expand_inherited = true)
        if !environment[name] && !inherited_environment[name] && !SYSTEM_ENV[name]
            nil
        else
            inherited =
                if expand_inherited
                    inherited_environment[name] || []
                elsif env_inherit?(name)
                    ["$#{name}"]
                else []
                end


            value = []
            [environment[name], inherited, SYSTEM_ENV[name]].each do |paths|
                (paths || []).each do |p|
                    if !value.include?(p)
                        value << p
                    end
                end
            end
            value
        end
    end

    def self.env_update_var(name)
        if value = env_value(name)
            ENV[name] = value.join(ENV_LIST_SEPARATOR)
        else
            ENV.delete(name)
        end
    end

    def self.env_add_path(name, *paths)
        oldpath = environment[name] || Array.new
        paths.reverse.each do |path|
            next if oldpath.include?(path)

            env_add(name, path)
            oldpath << path
            if name == 'RUBYLIB'
                $LOAD_PATH.unshift path
            end
        end
    end

    def self.env_remove_path(name, *paths)
        paths.each do |p|
            environment[name].delete(p)
        end
        env_update_var(name)
    end

    def self.env_push_path(name, *values)
        if current = environment[name]
            current = current.dup
            env_clear(name)
            env_add_path(name, *values)
            env_add_path(name, *current)
        else
            env_add_path(name, *values)
        end
    end

    # Require that generated environment variable scripts source the given shell
    # script
    def self.env_source_file(file)
        env_source_after(file)
    end

    # Require that generated environment variable scripts source the given shell
    # script
    def self.env_source_before(file)
        @env_source_before << file
    end

    # Require that generated environment variable scripts source the given shell
    # script
    def self.env_source_after(file)
        @env_source_after << file
    end

    # Generates a shell script that sets the environment variable listed in
    # Autobuild.environment, following the inheritance setting listed in
    # Autobuild.inherited_environment.
    #
    # It also sources the files added by Autobuild.env_source_file
    def self.export_env_sh(io)
        @env_source_before.each do |path|
            io.puts SHELL_SOURCE_SCRIPT % path
        end

        variables = []
        Autobuild.environment.each do |name, _|
            variables << name
            value = env_value(name, false)

            if value
                shell_line = SHELL_SET_COMMAND % [name, value.join(ENV_LIST_SEPARATOR)]
            else
                shell_line = SHELL_UNSET_COMMAND % [name]
            end
            io.puts shell_line
        end
        variables.each do |var|
            io.puts SHELL_EXPORT_COMMAND % [var]
        end
        @env_source_after.each do |path|
            io.puts SHELL_SOURCE_SCRIPT % [path]
        end
    end

    # DEPRECATED: use env_add_path instead
    def self.pathvar(path, varname)
        if File.directory?(path)
            if block_given?
                return unless yield(path)
            end
            env_add_path(varname, path)
        end
    end

    def self.each_env_search_path(prefix, patterns)
        arch_names = self.arch_names
        arch_size  = self.arch_size
        
        seen = Set.new
        patterns.each do |base_path|
            paths = []
            if base_path =~ /ARCHSIZE/
                base_path = base_path.gsub('ARCHSIZE', arch_size.to_s)
            end
            if base_path =~ /ARCH/
                arch_names.each do |arch|
                    paths << base_path.gsub('ARCH', arch)
                end
            else
                paths << base_path
            end
            paths.each do |p|
                p = File.join(prefix, *p.split('/'))
                if !seen.include?(p) && File.directory?(p)
                    yield(p)
                    seen << p
                end
            end
        end
    end

    def self.arch_size
        if @arch_size
            return @arch_size
        end

        @arch_size =
            if RbConfig::CONFIG['host_cpu'] =~ /64/
                64
            else 32
            end
    end

    def self.arch_names
        if @arch_names
            return @arch_names
        end

        result = Set.new
        if File.file?('/usr/bin/dpkg-architecture')
            arch = `/usr/bin/dpkg-architecture`.split.grep(/DEB_BUILD_MULTIARCH/).first
            if arch
                result << arch.chomp.split('=').last
            end
        end
        @arch_names = result
    end

    # Updates the environment when a new prefix has been added
    def self.update_environment(newprefix, includes = nil)
        if !includes || includes.include?('PATH')
            if File.directory?("#{newprefix}/bin")
                env_add_path('PATH', "#{newprefix}/bin")
            end
        end

        if !includes || includes.include?('PKG_CONFIG_PATH')
            pkg_config_search = ['lib/pkgconfig', 'lib/ARCH/pkgconfig', 'libARCHSIZE/pkgconfig']
            each_env_search_path(newprefix, pkg_config_search) do |path|
                env_add_path('PKG_CONFIG_PATH', path)
            end
        end

        if !includes || includes.include?('LD_LIBRARY_PATH')
            ld_library_search = ['lib', 'lib/ARCH', 'libARCHSIZE']
            each_env_search_path(newprefix, ld_library_search) do |path|
                if !Dir.glob(File.join(path, "lib*.so")).empty?
                    env_add_path('LD_LIBRARY_PATH', path)
                end
            end
        end

        # Validate the new rubylib path
        if !includes || includes.include?('RUBYLIB')
            new_rubylib = "#{newprefix}/lib"
            if File.directory?(new_rubylib) && !File.directory?(File.join(new_rubylib, "ruby")) && !Dir["#{new_rubylib}/**/*.rb"].empty?
                env_add_path('RUBYLIB', new_rubylib)
            end

            require 'rbconfig'
            ruby_arch    = File.basename(RbConfig::CONFIG['archdir'])
            candidates = %w{rubylibdir archdir sitelibdir sitearchdir vendorlibdir vendorarchdir}.
                map { |key| RbConfig::CONFIG[key] }.
                map { |path| path.gsub(/.*lib(?:32|64)?\//, '\\1') }.
                each do |subdir|
                    if File.directory?("#{newprefix}/lib/#{subdir}")
                        env_add_path("RUBYLIB", "#{newprefix}/lib/#{subdir}")
                    end
                end
        end
    end
end

