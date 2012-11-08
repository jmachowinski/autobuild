require 'autobuild/configurable'
require 'autobuild/packages/gnumake'

module Autobuild
    def self.cmake(options, &block)
        CMake.new(options, &block)
    end

    # Handler class to build CMake-based packages
    class CMake < Configurable
        class << self
            def builddir; @builddir || Configurable.builddir end
            def builddir=(new)
                raise ConfigException, "absolute builddirs are not supported" if (Pathname.new(new).absolute?)
                raise ConfigException, "builddir must be non-nil and non-empty" if (new.nil? || new.empty?)
                @builddir = new
            end

            attr_writer :full_reconfigures
            def full_reconfigures?
                @full_reconfigures
            end

            # Global default for the CMake generator to use. If nil (the
            # default), the -G option will not be given at all. Will work only
            # if the generator creates makefiles
            #
            # It can be overriden on a per-package basis with CMake.generator=
            attr_accessor :generator

            attr_reader :module_path
        end
        @module_path = []
        @full_reconfigures = true

        # a key => value association of defines for CMake
        attr_reader :defines
        # If true, always run cmake before make during the build
        attr_accessor :always_reconfigure
        # If true, we always remove the CMake cache before reconfiguring.
        # 
        # See #full_reconfigures? for more details
        attr_writer :full_reconfigures
        # Sets a generator explicitely for this component. See #generator and
        # CMake.generator
        attr_writer :generator
        # The CMake generator to use. You must choose one that generates
        # Makefiles. If not set for this package explicitely, it is using the
        # global value CMake.generator.
        def generator
            if @generator then @generator
            else CMake.generator
            end
        end

        # If true, we always remove the CMake cache before reconfiguring. This
        # is to workaround the aggressive caching behaviour of CMake, and is set
        # to true by default.
        #
        # See CMake.full_reconfigures? and CMake.full_reconfigures= for a global
        # setting
        def full_reconfigures?
            if @full_reconfigures.nil?
                CMake.full_reconfigures?
            else
                @full_reconfigures
            end
        end

        def cmake_cache; File.join(builddir, "CMakeCache.txt") end
        def configurestamp; cmake_cache end

        def initialize(options)
	    @defines = Hash.new
            super
        end

        def define(name, value)
            @defines[name] = value
        end

        def doc_dir
            if @doc_dir
                File.expand_path(@doc_dir, builddir)
            end
        end

        DOXYGEN_ACCEPTED_VARIABLES = {
            '@CMAKE_SOURCE_DIR@' => lambda { |pkg| pkg.srcdir },
            '@PROJECT_SOURCE_DIR@' => lambda { |pkg| pkg.srcdir },
            '@CMAKE_BINARY_DIR@' => lambda { |pkg| pkg.builddir },
            '@PROJECT_BINARY_DIR@' => lambda { |pkg| pkg.builddir },
            '@PROJECT_NAME@' => lambda { |pkg| pkg.name }
        }

        class << self
            # Flag controlling whether autobuild should run doxygen itself or
            # use the "doc" target generated by CMake
            #
            # This is experimental and OFF by default. See CMake#run_doxygen for
            # more details
            #
            # See also CMake#always_use_doc_target= and CMake#always_use_doc_target?
            # for a per-package control of that feature
            attr_writer :always_use_doc_target

            # Flag controlling whether autobuild should run doxygen itself or
            # use the "doc" target generated by CMake
            #
            # This is experimental and OFF by default. See CMake#run_doxygen for
            # more details
            #
            # See also CMake#always_use_doc_target= and CMake#always_use_doc_target?
            # for a per-package control of that feature
            def always_use_doc_target?
                @always_use_doc_target
            end
        end
        @always_use_doc_target = true

        # Flag controlling whether autobuild should run doxygen itself or
        # use the "doc" target generated by CMake
        #
        # This is experimental and OFF by default. See CMake#run_doxygen for
        # more details
        #
        # See also CMake.always_use_doc_target= and CMake.always_use_doc_target?
        # for a global control of that feature
        attr_reader :always_use_doc_target

        # Flag controlling whether autobuild should run doxygen itself or
        # use the "doc" target generated by CMake
        #
        # This is experimental and OFF by default. See CMake#run_doxygen for
        # more details
        #
        # See also CMake.always_use_doc_target= and CMake.always_use_doc_target?
        # for a global control of that feature
        def always_use_doc_target?
            if @always_use_doc_target.nil?
                return CMake.always_use_doc_target?
            else
                @always_use_doc_target
            end
        end

        # To avoid having to build packages to run the documentation target, we
        # try to autodetect whether (1) the package is using doxygen and (2)
        # whether the cmake variables in the doxyfile can be provided by
        # autobuild itself.
        #
        # This can be disabled globally by setting
        # Autobuild::CMake.always_use_doc_target= or on a per-package basis with
        # #always_use_doc_target=
        #
        # This method returns true if the package can use the internal doxygen
        # mode and false otherwise
        def internal_doxygen_mode?
            if always_use_doc_target?
                return false
            end

            doxyfile_in = File.join(srcdir, "Doxyfile.in")
            if !File.file?(doxyfile_in)
                return false
            end
            File.readlines(doxyfile_in).each do |line|
                matches = line.scan(/@[^@]+@/)
                if matches.any? { |str| !DOXYGEN_ACCEPTED_VARIABLES.has_key?(str) }
                    return false
                end
            end
        end

        # To avoid having to build packages to run the documentation target, we
        # try to autodetect whether (1) the package is using doxygen and (2)
        # whether the cmake variables in the doxyfile can be provided by
        # autobuild itself.
        #
        # This can be disabled globally by setting
        # Autobuild::CMake.always_use_doc_target or on a per-package basis with
        # #always_use_doc_target
        #
        # This method generates the corresponding doxygen file in
        # <builddir>/Doxygen and runs doxygen. It raises if the internal doxygen
        # support cannot be used on this package
        def run_doxygen
            doxyfile_in = File.join(srcdir, "Doxyfile.in")
            if !File.file?(doxyfile_in)
                raise RuntimeError, "no Doxyfile.in in this package, cannot use the internal doxygen support"
            end
            doxyfile_data = File.readlines(doxyfile_in).map do |line|
                line.gsub(/@[^@]+@/) { |match| DOXYGEN_ACCEPTED_VARIABLES[match].call(self) }
            end
            doxyfile = File.join(builddir, "Doxyfile")
            File.open(doxyfile, 'w') do |io|
                io.write(doxyfile_data)
            end
            Subprocess.run(self, 'doc', Autobuild.tool(:doxygen), doxyfile)
        end

        # Declare that the given target can be used to generate documentation
        def with_doc(target = 'doc')
            doc_task do
                in_dir(builddir) do
                    progress_start "generating documentation for %s", :done_message => 'generated documentation for %s' do
                        if internal_doxygen_mode?
                            run_doxygen
                        else
                            Subprocess.run(self, 'doc', Autobuild.tool(:make), "-j#{parallel_build_level}", target)
                        end
                        yield if block_given?
                    end
                end
            end
        end

        CMAKE_EQVS = {
            'ON' => 'ON',
            'YES' => 'ON',
            'OFF' => 'OFF',
            'NO' => 'OFF'
        }
        def equivalent_option_value?(old, new)
            if old == new
                true
            else
                old = CMAKE_EQVS[old]
                new = CMAKE_EQVS[new]
                if old && new
                    old == new
                else
                    false
                end
            end
        end

        def import
            super

            Dir.glob(File.join(srcdir, "*.pc.in")) do |file|
                file = File.basename(file, ".pc.in")
                provides "pkgconfig/#{file}"
            end
        end

        def prepare
            if !internal_doxygen_mode? && has_doc?
                task "#{name}-doc" => configurestamp
            end

            # A failed initial CMake configuration leaves a CMakeCache.txt file,
            # but no Makefile.
            #
            # Delete the CMakeCache to force reconfiguration
            if !File.exists?( File.join(builddir, 'Makefile') )
                FileUtils.rm_f cmake_cache
            end

            if File.exists?(cmake_cache)
                all_defines = defines.dup
                all_defines['CMAKE_INSTALL_PREFIX'] = prefix
                all_defines['CMAKE_MODULE_PATH'] = "#{CMake.module_path.join(";")}"
                cache = File.read(cmake_cache)
                did_change = all_defines.any? do |name, value|
                    cache_line = cache.each_line.find do |line|
                        line =~ /^#{name}:/
                    end

                    value = value.to_s
                    old_value = cache_line.split("=")[1].chomp if cache_line
                    if !old_value || !equivalent_option_value?(old_value, value)
                        if Autobuild.debug
                            message "%s: option '#{name}' changed value: '#{old_value}' => '#{value}'"
                        end
                        if old_value
                            message "%s: changed value of #{name} from #{old_value} to #{value}"
                        else
                            message "%s: setting value of #{name} to #{value}"
                        end
                        
                        true
                    end
                end
                if did_change
                    if Autobuild.debug
                        message "%s: CMake configuration changed, forcing a reconfigure"
                    end
                    FileUtils.rm_f cmake_cache
                end
            end

            super
        end

        # Configure the builddir directory before starting make
        def configure
            super do
                in_dir(builddir) do
                    if !File.file?(File.join(srcdir, 'CMakeLists.txt'))
                        raise ConfigException.new(self, 'configure'), "#{srcdir} contains no CMakeLists.txt file"
                    end

                    command = [ "cmake", "-DCMAKE_INSTALL_PREFIX=#{prefix}", "-DCMAKE_MODULE_PATH=#{CMake.module_path.join(";")}" ]

					if(RbConfig::CONFIG["host_os"] =~%r!(msdos|mswin|djgpp|mingw|[Ww]indows)!)
						command << '-G' 
						command << "MSYS Makefiles"
					end
					
                    defines.each do |name, value|
                        command << "-D#{name}=#{value}"
                    end
                    if generator
                        command << "-G#{generator}"
                    end
                    command << srcdir
                    
                    progress_start "configuring CMake build system for %s", :done_message => "configured CMake build system for %s" do
                        if full_reconfigures?
                            FileUtils.rm_f cmake_cache
                        end
                        Subprocess.run(self, 'configure', *command)
                    end
                end
            end
        end

        # Do the build in builddir
        def build
            in_dir(builddir) do
                progress_start "building %s", :done_message => "built %s" do
                    if always_reconfigure || !File.file?('Makefile')
                        Subprocess.run(self, 'build', Autobuild.tool(:cmake), '.')
                    end

                    Autobuild.make_subcommand(self, 'build') do |line|
                        if line =~ /\[\s+(\d+)%\]/
                            progress "building %s (#{Integer($1)}%%)"
                        end
                    end

                    warning = String.new
                    Autobuild.make_subcommand(self, 'build') do |line|
                        iswarning = false
                        if line =~ /\[\s*(\d+)%\]/
                            progress "building %s (#{Integer($1)}%%)"
                        elsif (line =~
/^(Linking)|^(Scanning)|^(Building)|^(Built)/) == nil
                            warning += line
                            iswarning = true
                        end
                        if(!iswarning && !warning.empty?)
                            warning.split("\n").each do |l|
                                message "%s: #{l}", :magenta
                            end
                            warning = ""
                        end
                    end
                end
            end
            Autobuild.touch_stamp(buildstamp)
        end

        # Install the result in prefix
        def install
            in_dir(builddir) do
                progress_start "installing %s", :done_message => 'installed %s' do
                    Subprocess.run(self, 'install', Autobuild.tool(:make), "-j#{parallel_build_level}", 'install')
                end
            end
            super
        end
    end
end

