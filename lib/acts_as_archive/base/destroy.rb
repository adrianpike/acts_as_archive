module ActsAsArchive
  module Base
    module Destroy

      def self.included(base)
        unless base.included_modules.include?(InstanceMethods)
          base.class_eval do
            alias_method :destroy_without_callbacks!, :destroy_without_callbacks
            class <<self
              alias_method :delete_all!, :delete_all
            end
          end
          base.send :extend, ClassMethods
          base.send :include, InstanceMethods
        end
      end

      module ClassMethods
        def copy_to_archive(conditions)
          add_conditions!(where = '', conditions)
          connection.execute(%{
            INSERT INTO archived_#{table_name} (#{column_names.join(', ')}, deleted_at)
              SELECT #{column_names.join(', ')}, '#{Time.now.to_s(:db)}'
              FROM #{table_name}
              #{where}
          })
          if where.empty?
            connection.execute("TRUNCATE TABLE #{table_name}")
          else
            connection.execute("DELETE FROM #{table_name} #{where}")
          end
        end
      
        def delete_all(conditions=nil)
          copy_to_archive(conditions)
        end
      end

      module InstanceMethods
        def destroy_without_callbacks
          unless new_record?
            self.class.copy_to_archive("#{self.class.primary_key} = #{id}")
          end
          freeze
        end

        def destroy!
          transaction { destroy_with_callbacks! }
        end

        def destroy_with_callbacks!
          return false if callback(:before_destroy) == false
          result = destroy_without_callbacks!
          callback(:after_destroy)
          result
        end
      end
    end
  end
end