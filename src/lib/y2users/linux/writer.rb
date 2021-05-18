# Copyright (c) [2021] SUSE LLC
#
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, contact SUSE LLC.
#
# To contact SUSE LLC about this file by physical or electronic mail, you may
# find current contact information at www.suse.com.

require "yast"
require "yast/i18n"
require "yast2/execute"
require "y2issues"

module Y2Users
  module Linux
    # Writes users and groups to the system using Yast2::Execute and standard
    # linux tools.
    #
    # NOTE: currently it only creates new users or modifies the password value
    # of existing ones.  Removing or fully modifying users is still not covered.
    # No group management or passowrd configuration either.
    #
    # A brief history of the differences with the Yast::Users (perl) module:
    #
    # Both useradd and YaST::Users call the helper script useradd.local which
    # performs several actions at the end of the user creation process. Those
    # actions has changed over time. See chapters below.
    #
    # Chapter 1 - skel files
    #
    # Historically, both useradd and YaST took the reponsibility of copying
    # files from /etc/skel to the home directory of the new user.
    #
    # Then, useradd.local copied files from /usr/etc/skel (note the "usr" part)
    #
    # So the files from /usr/etc/skel were always copied to the home directory
    # if possible, no matter if it was actually created during the process or it
    # already existed before (both situations look the same to useradd.local).
    #
    # Equally, YaST always copied the /etc/skel files and did all the usual
    # operations in the home directory (eg. adjusting ownership).
    #
    # That YaST behavior was different to what useradd does. It skips copying
    # skel and other actions if the home directory existed in advance.
    #
    # The whole management of skel changed as consequence of boo#1173321
    #   - Factory sr#872327 and SLE sr#235709
    #     * useradd.local does not longer deal with skel files
    #     * useradd copies files from both /etc/skel and /usr/etc/skel
    #   - https://github.com/yast/yast-users/pull/240
    #     * Equivalent change for Yast (copy both /etc/skel & /usr/etc/skel)
    #
    # Chapter 2 - updating the NIS database
    #
    # At some point in time, useradd.local took care of updating the NIS
    # database executing "make -C /var/yp". That part of the script was commented
    # out at some point in time, so it does not do it anymore.
    #
    # Yast::Users also takes care of updating the NIS database calling the very
    # same command (introduced at commit eba0eddc5d72 on Jan 7, 2004)
    # Bear in mind that YaST only executes that "make" command once, after
    # having removed, modified and created all users. So the database gets
    # updated always, no matter whether useradd.local has been called.
    #
    # NOTE: no support for the Yast::Users option no_skeleton
    # NOTE: no support for the Yast::Users chown_home=0 option (what is good for?)

    # TODO: no plugin support yet
    # TODO: no authorized keys yet
    class Writer
      include Yast::I18n
      include Yast::Logger
      # Constructor
      #
      # @param config [Y2User::Config] see #config
      # @param initial_config [Y2User::Config] see #initial_config
      def initialize(config, initial_config)
        textdomain "y2users"

        @config = config
        @initial_config = initial_config
      end

      # Performs the changes in the system
      #
      # @return [Y2Issues::List] the list of issues found while writing changes; empty when none
      def write
        issues = Y2Issues::List.new

        users_finder.added.each { |u| add_user(u, issues) }
        users_finder.password_edited.each { |u| change_password(u, issues) }

        refresh_databases

        issues
      end

    private

      # Configuration containing the users and groups that should exist in the system after writing
      #
      # @return [Y2User::Config]
      attr_reader :config

      # Initial state of the system (usually a Y2User::Config.system in a running system) that will
      # be compared with {#config} to know what changes need to be performed.
      #
      # @return [Y2User::Config]
      attr_reader :initial_config

      # Command for creating new users
      USERADD = "/usr/sbin/useradd".freeze
      private_constant :USERADD

      # Command for setting a user password
      #
      # This command is "preferred" over
      #   * the `passwd` command because the password at this point is already
      #   encrypted (see Y2Users::Password#value). Additionally, this command
      #   requires to enter the password twice, which it's not possible using
      #   the Cheetah stdin argument.
      #
      #   * the `--password` useradd option because the encrypted
      #   password is visible as part of the process name
      CHPASSWD = "/usr/sbin/chpasswd".freeze
      private_constant :CHPASSWD

      # Command for configuring the attributes in /etc/shadow
      CHAGE = "/usr/bin/chage".freeze
      private_constant :CHAGE

      def users_finder
        @users_finder ||= UsersFinder.new(initial_config, config)
      end

      # Executes the command for creating the user
      #
      # @param user [Y2User::User] the user to be created on the system
      # @param issues [Y2Issues::List] a collection for adding an issue if something goes wrong
      def add_user(user, issues)
        Yast::Execute.on_target!(USERADD, *useradd_options(user))
        change_password(user, issues) if user.password
      rescue Cheetah::ExecutionFailed => e
        issues << Y2Issues::Issue.new(
          format(_("The user '%{username}' could not be created"), username: user.name)
        )
        log.error("Error creating user '#{user.name}' - #{e.message}")
      end

      # Executes the commands for setting the password and all its associated
      # attributes for the given user
      #
      # @param user [Y2User::User]
      # @param issues [Y2Issues::List] a collection for adding issues if something goes wrong
      def change_password(user, issues)
        set_password_value(user, issues)
        set_password_attributes(user, issues)
      end

      # Executes the command for setting the password of given user
      #
      # @param user [Y2User::User]
      # @param issues [Y2Issues::List] a collection for adding an issue if something goes wrong
      def set_password_value(user, issues)
        return unless user.password&.value

        Yast::Execute.on_target!(CHPASSWD, *chpasswd_options(user))
      rescue Cheetah::ExecutionFailed => e
        issues << Y2Issues::Issue.new(
          # TRANSLATORS: %s is a placeholder for a username
          format(_("The password for '%s' could not be set"), user.name)
        )
        log.error("Error setting password for '#{user.name}' - #{e.message}")
      end

      # Executes the command for setting the dates and limits in /etc/shadow
      #
      # @param user [Y2User::User]
      # @param issues [Y2Issues::List] a collection for adding an issue if something goes wrong
      def set_password_attributes(user, issues)
        return unless user.password

        Yast::Execute.on_target!(CHAGE, *chage_options(user))
      rescue Cheetah::ExecutionFailed => e
        issues << Y2Issues::Issue.new(
          # TRANSLATORS: %s is a placeholder for a username
          format(_("Error setting the properties of the password for '%s'"), user.name)
        )
        log.error("Error setting password attributes for '#{user.name}' - #{e.message}")
      end

      # Generates and returns the options expected by `useradd` for given user
      #
      # @param user [Y2Users::User]
      # @return [Array<String>]
      def useradd_options(user)
        opts = {
          "--uid"      => user.uid,
          "--gid"      => user.gid,
          "--shell"    => user.shell,
          "--home-dir" => user.home,
          "--comment"  => user.gecos.join(",")
        }
        opts = opts.reject { |_, v| v.to_s.empty? }.flatten

        if user.system?
          opts << "--system"
        else
          opts.concat(create_home_options(user))
        end

        opts << user.name
        opts
      end

      # Options for `useradd` to create the home directory
      #
      # @param _user [Y2Users::User]
      # @return [Array<String>]
      def create_home_options(_user)
        # TODO: "--btrfs-subvolume-home" if needed
        ["--create-home"]
      end

      # Generates and returns the options expected by `chpasswd` for the given user
      #
      # @param user [Y2Users::User]
      # @return [Array<String, Hash>]
      def chpasswd_options(user)
        opts = []
        opts << "-e" if user.password&.value&.encrypted?
        opts << {
          stdin:    [user.name, user.password&.value&.content].join(":"),
          recorder: cheetah_recorder
        }
        opts
      end

      # Generates and returns the options expected by `chage` for the given user
      #
      # @param user [Y2Users::User]
      # @return [Array<String>]
      def chage_options(user)
        passwd = user.password

        opts = []
        opts.concat(["--lastday", chage_value(passwd.aging.content)]) if passwd.aging

        opts.concat(
          [
            "--mindays",    chage_value(passwd.minimum_age),
            "--maxdays",    chage_value(passwd.maximum_age),
            "--warndays",   chage_value(passwd.warning_period),
            "--inactive",   chage_value(passwd.inactivity_period),
            "--expiredate", chage_value(passwd.account_expiration),
            user.name
          ]
        )

        opts
      end

      # @see #chage_options
      #
      # @param value [String, Integer, Date, nil]
      # @return [String]
      def chage_value(value)
        return "-1" if value.nil? || value == ""

        value.to_s
      end

      # Invalidates or recreates extra databases whose information is based in the information
      # stored in the shadow files, like NIS or nscd.
      def refresh_databases
        # TODO: update the NIS database (make -C /var/yp) if needed

        # Remove the passwd cache for nscd (bsc#24748, bsc#41648):
        # The nscd daemon watches for changes in the configuration files appropriate for each
        # database (e.g., /etc/passwd for the passwd database), and flushes the cache when these are
        # changed. But looks like that process is not perfect and is safer to enforce the refresh.
        nscd = Nscd.new
        nscd.invalidate_cache(:passwd) if users_changed?
        nscd.invalidate_cache(:group) if groups_changed?
      end

      # Whether there is any change in the users on the system
      #
      # @return [Boolean]
      def users_changed?
        users_finder.added.any? || users_finder.password_edited.any?
      end

      # Whether there is any change in the groups of the system
      #
      # @return [Boolean]
      def groups_changed?
        # TODO
        false
      end

      # Custom Cheetah recorder to prevent leaking the password to the logs
      #
      # @return [Recorder]
      def cheetah_recorder
        @cheetah_recorder ||= Recorder.new(Yast::Y2Logger.instance)
      end

      # Class to prevent Yast::Execute from leaking to the logs passwords
      # provided via stdin
      class Recorder < Cheetah::DefaultRecorder
        # To prevent leaking stdin, just do nothing
        def record_stdin(_stdin); end
      end

      # Helper class to find specific users
      class UsersFinder
        # Constructor
        #
        # @param initial [Config]
        # @param target [Config]
        def initialize(initial, target)
          @initial = initial
          @target = target
        end

        # Users from the target config that do not exist in the initial config
        #
        # @return [Array<User>]
        def added
          ids = target_ids - initial_ids

          ids.map { |i| find_user(target, i) }
        end

        # Users from the target config whose password does not match with its counterpart from the
        # initial config.
        #
        # @return [Array<User>]
        def password_edited
          ids = target_ids & initial_ids

          pairs = ids.map { |i| [find_user(target, i), find_user(initial, i)] }

          pairs.reject { |p| p.first.password == p.last.password }.map(&:first)
        end

      private

        # Initial config
        #
        # @return [Config]
        attr_reader :initial

        # Target config
        #
        # @return [Config]
        attr_reader :target

        # Finds an user with the given id inside the given config
        #
        # @param config [Config]
        # @param id [Integer]
        #
        # @return [User, nil] nil if user with the given id is not found
        def find_user(config, id)
          config.users.find { |u| u.id == id }
        end

        # All the users id from the initial config
        #
        # @return [Array<Integer>]
        def initial_ids
          users_id(initial)
        end

        # All the users id from the target config
        #
        # @return [Array<Integer>]
        def target_ids
          users_id(target)
        end

        # Users id from the given config
        #
        # @param config [Config]
        # @return [Array<Integer>]
        def users_id(config)
          config.users.map(&:id).compact
        end
      end

      # Inner class to manage the Name Service Caching Daemon
      class Nscd
        include Yast::Logger
        Yast.import "Package"

        # Command to control nscd
        COMMAND = "/usr/sbin/nscd".freeze
        # Package containing the Name Service Caching Daemon
        PACKAGE = "nscd".freeze
        private_constant :COMMAND, :PACKAGE

        # Whethet nscd is available in the target system
        def available?
          return @available unless @available.nil?

          @available = Yast::Package.Installed(PACKAGE)
        end

        # Invalidate the cache for the given nscd database
        #
        # @param database [#to_s] name of the database to invalidate
        def invalidate_cache(database)
          if !available?
            log.info "nscd is not installed, nothing to do for #{database}"
            return
          end

          Yast::Execute.on_target!(COMMAND, "-i", database.to_s)
          log.info "nscd cache invalidated: #{database}"
        rescue Cheetah::ExecutionFailed
          log.warn "Error invalidating nscd cache: #{database}"
        end
      end
    end
  end
end
