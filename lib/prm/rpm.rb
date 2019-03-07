#!/usr/bin/env ruby

require 'arr-pm'
require 'fileutils'
require 'peach'
require 'digest'
require 'zlib'

module Redhat
    def build_rpm_repo(path,arch,release,gpg,silent)
        arch.peach do |a|
            release.peach do |r|
                full_path = "#{path}/#{r}/#{a}/"
                repo_path = "#{full_path}/repodata/"

                if !File.exists?(full_path)
                    FileUtils.mkdir_p(full_path)
                end

                if !File.exists?(repo_path)
                    FileUtils.mkdir(repo_path)
                end

                pkgnum = 0
                hpkgnum = Hash.new
                Dir.glob("#{full_path}/*.rpm").each do |file|
                    pkgnum = pkgnum + 1
                    hpkgnum.store(file, pkgnum)
                end

                primary_xml = Array.new
                filelists_xml = Array.new
                other_xml = Array.new
                package_count = 0

                Dir.glob("#{full_path}/*.rpm").peach do |file|
                    package_count = package_count + 1
                    time = Time.now
                    sha256sum = Digest::SHA256.file(file).hexdigest
                    rpm = RPM::File.new(file)
                    filesize = File.size?(file)
                    pkgmeta = Hash[*rpm.header.tags.collect { |t| [t.tag, t.value] }.inject([]) { |m,v| m + v }]
                    start_header = rpm.lead.length + rpm.signature.length
                    end_header = start_header + rpm.header.length
                    pkgnum = hpkgnum[file]

                    primary_xml << create_primary_xml(file, time, sha256sum, rpm, filesize, pkgmeta, start_header, end_header, pkgnum)
                    other_xml << create_other_xml(file, time, sha256sum, rpm, filesize, pkgmeta, start_header, end_header, pkgnum)
                    filelists_xml << create_filelists_xml(file, time, sha256sum, rpm, filesize, pkgmeta, start_header, end_header, pkgnum)
                end

                erb_files = %w{
                    primary
                    other
                    filelists
                }

                template_dir = File.join(File.dirname(__FILE__), "..", "..", "templates")

                erb_files.each { |f|
                    erb = ERB.new(File.read("#{template_dir}/#{f}.xml.erb"), nil, "-").result(binding)

                    release_file = File.new("#{repo_path}/#{f}.xml","wb")
                    release_file.puts erb
                    release_file.close
                }

                xml_data_hash = Hash.new
                xml_data_hash = {
                    "filelists" => {
                        "xml"   => "",
                        "gz"    => "",
                        "size"  => "",
                        "osize" => "",
                    },
                    "other"     => {
                        "xml"   => "",
                        "gz"    => "",
                        "size"  => "",
                        "osize" => "",
                    },
                    "primary"   => {
                        "xml"   => "",
                        "gz"    => "",
                        "size"  => "",
                        "osize" => "",
                    }
                }

                Dir.glob("#{repo_path}/*.gz") { |f|
                    FileUtils.rm(f)
                }

                erb_files.each { |file|
                    xml_data_hash[file]["osize"] = File.size?("#{repo_path}/#{file}.xml")
                    xml_data_hash[file]["xml"] = Digest::SHA256.file("#{repo_path}/#{file}.xml").hexdigest

                    Zlib::GzipWriter.open("#{repo_path}/#{file}.xml.gz") do |gz|
                        ff = File.new("#{repo_path}/#{file}.xml", "r")
                        ff.each do |line|
                            gz.write(line)
                        end
                    end

                    xml_data_hash[file]["size"] = File.size?("#{repo_path}/#{file}.xml.gz")
                    xml_data_hash[file]["gz"] = Digest::SHA256.file("#{repo_path}/#{file}.xml.gz").hexdigest

                    FileUtils.rm("#{repo_path}/#{file}.xml")
                    FileUtils.mv("#{repo_path}/#{file}.xml.gz", "#{repo_path}/#{xml_data_hash[file]['gz']}-#{file}.xml.gz")
                }

                repomd_xml = Array.new
                timestamp = Time.now.to_i

                repomd_xml << create_repomd_xml(xml_data_hash,timestamp)
                erb_two = ERB.new(File.open("#{template_dir}/repomd.xml.erb", "r") { |file|
                    file.read
                }).result(binding)

                r_file = File.new("#{repo_path}/repomd.xml.tmp","wb")
                r_file.puts erb_two
                r_file.close

                FileUtils.mv("#{repo_path}/repomd.xml.tmp", "#{repo_path}/repomd.xml")

                unless gpg == false
                    # We expect that GPG is installed and a key has already been made
                    sign_cmd = "gpg -u #{gpg} --no-tty --yes --detach-sign --armor #{repo_path}/repomd.xml"
                    system sign_cmd
                end
                
                puts "Built Yum repository for #{r}\n"
            end
        end
    end

    def move_rpm_packages(path,arch,release,directory)
        unless File.exists?(directory)
            puts "ERROR: #{directory} doesn't exist... not doing anything\n"
            return false
        end

        files_moved = Array.new
        release.each { |r|
            arch.each { |a|
                puts a
                Dir.glob(directory + "/*.rpm") do |file|
                        puts "Include #{file}"
                        FileUtils.cp(file, "#{path}/#{r}/#{a}/")
                end
            }
        }

        files_moved.each do |f|
            if File.exists?(f)
                FileUtils.rm(f)
            end
        end
    end

    def create_repomd_xml(xml_data_hash,timestamp)
        repomd_meta = String.new
        xml_data_hash.each_pair do |k,v|
            repomd_meta <<
            %Q(<data type="#{k}">
                <checksum type="sha256">#{v["gz"]}</checksum>
                <open-checksum type="sha256">#{v["xml"]}</open-checksum>
                <location href="repodata/#{v["gz"]}-#{k}.xml.gz"/>
                <timestamp>#{timestamp}</timestamp>
                <size>#{v["size"]}</size>
                <open-size>#{v["osize"]}</open-size>
            </data>)
        end
        return repomd_meta
    end

    def create_filelists_xml(file, time, sha256sum, rpm, filesize, pkgmeta, start_header, end_header, pkgnum)
        init_filelists_data = String.new
        epoch = (pkgmeta[:epoch]) ? pkgmeta[:epoch].first : 0
        init_filelists_data <<    
        %Q(<package pkgid="#{sha256sum}" name="#{pkgmeta[:name]}" arch="#{pkgmeta[:arch]}">
        <version epoch="#{epoch}" ver="#{pkgmeta[:version]}" rel="#{pkgmeta[:release]}"/>\n\n)

        rpm.files.each do |file|
            init_filelists_data << %Q(        <file>#{file}</file>\n)
        end

        init_filelists_data <<
        %Q(</package>)
        return init_filelists_data
    end

    def create_other_xml(file, time, sha256sum, rpm, filesize, pkgmeta, start_header, end_header, pkgnum)
        init_other_data = String.new
        epoch = (pkgmeta[:epoch]) ? pkgmeta[:epoch].first : 0
        init_other_data << 
        %Q(<package pkgid="#{sha256sum}" name="#{pkgmeta[:name]}" arch="#{pkgmeta[:arch]}">
           <version epoch="#{epoch}" ver="#{pkgmeta[:version]}" rel="#{pkgmeta[:release]}"/>\n)
           init_other_data <<
           %Q(</package>)

           return init_other_data
    end

    def create_primary_xml(file, time, sha256sum, rpm, filesize, pkgmeta, start_header, end_header, pkgnum)
        time = time.to_i
        cut_file = File.basename(file)
        epoch = (pkgmeta[:epoch]) ? pkgmeta[:epoch].first : 0
        init_primary_data = String.new
        init_primary_data = %Q(<package type=\"rpm\">
        <name>#{pkgmeta[:name]}</name>
        <arch>#{pkgmeta[:arch]}</arch>
        <version epoch=\"#{epoch}\" ver=\"#{pkgmeta[:version]}\" rel=\"#{pkgmeta[:release]}\"/>
        <checksum type=\"sha256\" pkgid=\"YES\">#{sha256sum}</checksum>
        <summary>#{pkgmeta[:summary]}</summary>
        <description>#{pkgmeta[:description]}</description>
        <packager></packager>
        <url>#{pkgmeta[:url]}</url>
        <time file=\"#{time}\" build=\"#{time}\"/>
        <size package=\"#{filesize}\" installed=\"\" archive=\"\"/>
        <location href=\"#{cut_file}\"/>
        <format>
        <rpm:license>#{pkgmeta[:license]}</rpm:license>
        <rpm:vendor/>
        <rpm:group>#{pkgmeta[:group]}</rpm:group>
        <rpm:buildhost>#{pkgmeta[:buildhost]}</rpm:buildhost>
        <rpm:sourcerpm>#{pkgmeta[:sourcerpm]}</rpm:sourcerpm>\n)
#        <rpm:header-range start=\"#{start_header}\" end=\"#{end_header}\"/ >\n)

        provide_primary_data = String.new
        if !rpm.provides.empty?
            provide_primary_data << "<rpm:provides>\n"
            rpm.provides.each do |prov|
                name = prov[0]
                prov[1].nil? ? flag = "" : flag = prov[1]
                flag = "EQ" if flag == "="
                if prov[2].nil?
                    epoch = 0 && version = "" && release = ""
                else
                    if prov[2].include?(":")
                        prov_arr = prov[2].split(":")
                        epoch = prov_arr[0]
                        version,release = prov_arr[1].split(/-/)
                    else
                        epoch = 0
                        version,release = prov[2].split(/-/)
                    end
                end
                if !flag.empty?
                    provide_primary_data << 
                    "<rpm:entry name=\"#{name}\" flags=\"#{flag}\" epoch=\"#{epoch}\" ver=\"#{version}\" rel=\"#{release}\"/>\n"
                else
                    provide_primary_data << 
                    "<rpm:entry name=\"#{name}\"/>\n"
                end
            end
            provide_primary_data << "</rpm:provides>\n"
        end

        init_primary_data = init_primary_data + provide_primary_data

        require_primary_data = String.new
        if !rpm.requires.empty?
            require_primary_data << "<rpm:requires>\n"
            rpm.requires.each do |req|
                next if req[0] =~ /^rpmlib/
                name = req[0]
                req[1].nil? ? flag = "" : flag = req[1]
                if req[2].nil?
                    epoch = 0 && version = "" && release = ""
                else
                    if req[2].include?(":")
                        req_arr = req[2].split(":")
                        epoch = req_arr[0]
                        version,release = req_arr[1].split(/-/)
                    else
                        epoch = 0
                        version,release = req[2].split(/-/)
                    end
                end
                if !flag.empty?
                  require_primary_data <<
                  "<rpm:entry name=\"#{name}\" flags=\"#{flag}\" epoch=\"#{epoch}\" ver=\"#{version}\" rel=\"#{release}\"/>\n"
                else
                  require_primary_data <<
                  "<rpm:entry name=\"#{name}\"/>\n"
                end
            end
            require_primary_data << "</rpm:requires>\n"
        end

        init_primary_data = init_primary_data + require_primary_data

        conflict_primary_data = String.new
        if !rpm.conflicts.empty?
            conflict_primary_data << "<rpm:conflicts>\n"
            rpm.conflicts.each do |con|
                name = con[0]
                conflict_primary_data <<
                "<rpm:entry name=\"#{name}\">\n"
            end
            conflict_primary_data << "</rpm:conflicts>\n"
        end

        init_primary_data + conflict_primary_data

        files_primary_data = String.new
        rpm.files.each do |file|
            files_primary_data <<
            "<file>#{file}</file>"
        end

        init_primary_data + files_primary_data

        init_primary_data << 
        %Q(        </format>\n) + %Q(</package>)

        return init_primary_data
    end
end
