require File.dirname(__FILE__) + '/acts_as_archive/gems'

ActsAsArchive::Gems.activate %w(also_migrate mover)

require 'also_migrate'
require 'mover'

$:.unshift File.dirname(__FILE__)

class ActsAsArchive
  class <<self
    
    attr_accessor :configuration, :disabled
    
    def deprecate(msg)
      if defined?(::ActiveSupport::Deprecation)
        ::ActiveSupport::Deprecation.warn msg
      else
        $stdout.puts msg
      end
    end
    
    def disable(&block)
      @mutex ||= Mutex.new
      @mutex.synchronize do
        self.disabled = true
        block.call
      end
    ensure
      self.disabled = false
    end
    
    def find(from)
      from = [ from ] unless from.is_a?(::Array)
      
      (@configuration || []).select do |hash|
        if from[0].is_a?(::String)
          from.include?(hash[:from].table_name)
        else
          from.include?(hash[:from])
        end
      end
    end
    
    def move(config, where, merge_options={})
      config[:to].each do |to|
        options = config[:options].dup.merge(merge_options)
        if options[:conditions]
          options[:conditions] += " AND #{where}"
        elsif where
          options[:conditions] = where
        end
        config[:from].move_to(to, options)
      end
    end
    
    def update(*args)
      deprecate "ActsAsArchive.update is deprecated and no longer necessary."
    end
  end
  
  module Base
    def self.included(base)
      unless base.included_modules.include?(InstanceMethods)
        base.extend ClassMethods
        base.send :include, InstanceMethods
      end
    end

    module ClassMethods
      def acts_as_archive(*args)
        return unless ActsAsArchive.find(self).empty?
        
        ActsAsArchive.configuration ||= []
        ActsAsArchive.configuration << (config = { :from => self })
        
        options = args.last.is_a?(::Hash) ? args.pop : {}
        options[:copy] = true
        
        if options[:archive]
          options[:magic] = 'restored_at'
        else
          options[:magic] = 'deleted_at' if options[:magic].nil?
          options[:add] = [[ options[:magic], :datetime ]]
          options[:ignore] = options[:magic]
          options[:subtract] = 'restored_at'
          options[:timestamps] = false if options[:timestamps].nil?
          
          if args.empty?
            class_eval <<-EVAL
              class Archive < ActiveRecord::Base
                set_table_name "archived_#{self.table_name}"
              end
            EVAL
            args << self::Archive
          end
        
          args.each do |klass|
            klass.class_eval <<-EVAL
              record_timestamps = #{options[:timestamps].inspect}
              acts_as_archive(#{self}, :archive => true)
            EVAL
            self.reflect_on_all_associations.each do |association|
              if !ActsAsArchive.find(association.klass).empty? && association.options[:dependent]
                opts = association.options.dup
                opts[:class_name] = "::#{association.class_name}::Archive"
                opts[:foreign_key] = association.primary_key_name
                klass.send association.macro, association.name, opts
              end
            end
            unless options[:migrate] == false
              self.also_migrate klass.table_name, options
            end
          end
        end
        
        config[:to] = args
        config[:options] = options
      end
      
      def delete_all!(*args)
        ActsAsArchive.disable { self.delete_all(*args) }
      end
      
      def destroy_all!(*args)
        ActsAsArchive.disable { self.destroy_all(*args) }
      end
      
      def migrate_from_acts_as_paranoid
        time = Benchmark.measure do
          ActsAsArchive.find(self).each do |config|
            config = config.dup
            config[:options][:copy] = false
            ActsAsArchive.move(
              config,
              "`#{config[:options][:magic]}` IS NOT NULL",
              :migrate => true
            )
          end
        end
        $stdout.puts "-- #{self}.migrate_from_acts_as_paranoid"
        $stdout.puts "   -> #{"%.4fs" % time.real}"
      end
      
      def restore_all(*args)
        ActsAsArchive.deprecate "#{self}.restore_all is deprecated, please use #{self}.delete_all."
        self.delete_all *args
      end
    end
    
    module InstanceMethods
      def delete!(*args)
        ActsAsArchive.disable { self.delete(*args) }
      end
      
      def destroy!(*args)
        ActsAsArchive.disable { self.destroy(*args) }
      end
    end
  end
  
  module DatabaseStatements
    def self.included(base)
      unless base.included_modules.include?(InstanceMethods)
        base.send :include, InstanceMethods
        base.class_eval do
          unless method_defined?(:delete_sql_without_archive)
            alias_method :delete_sql_without_archive, :delete_sql
            alias_method :delete_sql, :delete_sql_with_archive
          end
        end
      end
    end
    
    module InstanceMethods
      def delete_sql_with_archive(sql, name = nil)
        @mutex ||= Mutex.new
        @mutex.synchronize do

          unless ActsAsArchive.disabled
            from, where = /DELETE FROM (.+)/i.match(sql)[1].split(/\s+WHERE\s+/i, 2)
            from = from.strip.gsub(/`/, '').gsub('"','').split(/\s*,\s*/)
        
            ActsAsArchive.find(from).each do |config|
              ActsAsArchive.move(config, where)
            end
          end
        end
        
        delete_sql_without_archive(sql, name)
      end
    end
  end
end

::ActiveRecord::Base.send(:include, ::ActsAsArchive::Base)
::ActiveRecord::ConnectionAdapters::DatabaseStatements.send(:include, ::ActsAsArchive::DatabaseStatements)