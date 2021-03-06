module ActiveRecord
  module Acts
    module TaggableOn
      def self.included(base)
        base.extend(ClassMethods)
      end
      
      module ClassMethods
        def taggable?
          false
        end
        
        def acts_as_taggable
          acts_as_taggable_on :tags
        end
        
        def acts_as_taggable_on(*args)
          args.flatten! if args
          args.compact! if args
          for tag_type in args
            tag_type = tag_type.to_s
            self.class_eval do
              has_many "#{tag_type.singularize}_taggings".to_sym, :as => :taggable, :dependent => :destroy, 
                :include => :tag, :conditions => ["context = ?",tag_type], :class_name => "Tagging"
              has_many "#{tag_type}".to_sym, :through => "#{tag_type.singularize}_taggings".to_sym, :source => :tag
            end
            
            self.class_eval <<-RUBY
              def self.taggable?
                true
              end
              
              def self.caching_#{tag_type.singularize}_list?
                caching_tag_list_on?("#{tag_type}")
              end
              
              def self.#{tag_type.singularize}_counts(options={})
                tag_counts_on('#{tag_type}',options)
              end
        
              def #{tag_type.singularize}_list
                tag_list_on('#{tag_type}')
              end
            
              def #{tag_type.singularize}_list=(new_tags)
                set_tag_list_on('#{tag_type}',new_tags)
              end
            
              def #{tag_type.singularize}_counts(options = {})
                tag_counts_on('#{tag_type}',options)
              end
              
              def #{tag_type}_from(owner)
                tag_list_on('#{tag_type}', owner)
              end
              
              def find_related_#{tag_type}(options = {})
                related_tags_for('#{tag_type}', self.class, options)
              end
              alias_method :find_related_on_#{tag_type}, :find_related_#{tag_type}

              def find_related_#{tag_type}_for(klass, options = {})
                related_tags_for('#{tag_type}', klass, options)
              end
            RUBY
          end      
          
          if respond_to?(:tag_types)
            write_inheritable_attribute( :tag_types, (tag_types + args).uniq )
          else
            self.class_eval do
              write_inheritable_attribute(:tag_types, args.uniq)
              class_inheritable_reader :tag_types
            
              has_many :taggings, :as => :taggable, :dependent => :destroy, :include => :tag
              has_many :base_tags, :class_name => "Tag", :through => :taggings, :source => :tag
            
              attr_writer :custom_contexts
            
              before_save :save_cached_tag_list
              after_save :save_tags
              
              if respond_to?(:named_scope)
                named_scope :tagged_with, lambda{ |tags, options|
                  find_options_for_find_tagged_with(tags, options)
                }
              end
            end
            
            include ActiveRecord::Acts::TaggableOn::InstanceMethods
            extend ActiveRecord::Acts::TaggableOn::SingletonMethods                
            alias_method_chain :reload, :tag_list
          end
        end
        
        def is_taggable?
          false
        end
      end
      
      module SingletonMethods
        # Pass either a tag string, or an array of strings or tags
        # 
        # Options:
        #   :exclude - Find models that are not tagged with the given tags
        #   :match_all - Find models that match all of the given tags, not just one
        #   :conditions - A piece of SQL conditions to add to the query
        #   :on - scopes the find to a context
        def find_tagged_with(*args)
          options = find_options_for_find_tagged_with(*args)
          options.blank? ? [] : find(:all,options)
        end
        
        def caching_tag_list_on?(context)
          column_names.include?("cached_#{context.to_s.singularize}_list")
        end     
        
        def tag_counts_on(context, options = {})
          Tag.find(:all, find_options_for_tag_counts(options.merge({:on => context.to_s})))
        end           
        
        def find_options_for_find_tagged_with(tags, options = {})
          tags = tags.is_a?(Array) ? TagList.new(tags.map(&:to_s)) : TagList.from(tags)

          return {} if tags.empty?

          conditions = []
          tagging_joins = []
          tag_joins = []
          
          conditions << sanitize_sql(options.delete(:conditions)) if options[:conditions]
          
          taggings_alias = connection.quote_table_name "#{table_name}_taggings"
          tags_alias = connection.quote_table_name "#{table_name}_tags"
          table_alias = connection.quote_table_name table_name
          
          unless (on = options.delete(:on)).nil?
            tagging_joins << ["#{taggings_alias}.context = ?", on.to_s]
          end
          
          tagging_joins << "#{taggings_alias}.taggable_id = #{table_alias}.#{connection.quote_column_name primary_key}"
          tagging_joins << ["#{taggings_alias}.taggable_type = ?", base_class.name]
          
          tag_joins << "#{tags_alias}.id = #{taggings_alias}.tag_id"
          tag_joins << ["lower(#{tags_alias}.name) IN (?)", tags.map{|x|x.downcase}]

          if options.delete(:exclude)
            conditions << "(#{taggings_alias}.id IS NULL OR #{tags_alias}.id IS NULL)"
            join_type = 'LEFT OUTER JOIN'
          else
            conditions << "#{tags_alias}.id IS NOT NULL"
            join_type = 'JOIN'

            if options.delete(:match_all)
              group = sanitize_sql(["#{taggings_alias}.taggable_id HAVING COUNT(#{taggings_alias}.taggable_id) = ?", tags.size])
            end
          end
          
          tagging_joins = "#{join_type} #{connection.quote_table_name Tagging.table_name} AS #{taggings_alias} ON " +
              tagging_joins.map{|x| sanitize_sql(x)}.join(' AND ')
          
          tag_joins = "#{join_type} #{connection.quote_table_name Tag.table_name} AS #{tags_alias} ON " +
              tag_joins.map{|x| sanitize_sql(x)}.join(' AND ')
          
          { :select => "DISTINCT #{table_name}.*",
            :joins => "#{tagging_joins} #{tag_joins}",
            :conditions => conditions.map{|x| sanitize_sql(x)}.join(' AND '),
            :group      => group
          }.update(options)
        end    
        
        # Calculate the tag counts for all tags.
        # 
        # Options:
        #  :start_at - Restrict the tags to those created after a certain time
        #  :end_at - Restrict the tags to those created before a certain time
        #  :conditions - A piece of SQL conditions to add to the query
        #  :limit - The maximum number of tags to return
        #  :order - A piece of SQL to order by. Eg 'tags.count desc' or 'taggings.created_at desc'
        #  :at_least - Exclude tags with a frequency less than the given value
        #  :at_most - Exclude tags with a frequency greater than the given value
        #  :on - Scope the find to only include a certain context
        def find_options_for_tag_counts(options = {})
          options.assert_valid_keys :start_at, :end_at, :conditions, :at_least, :at_most, :order, :limit, :on
          
          scope = scope(:find)
          start_at = sanitize_sql(["#{Tagging.table_name}.created_at >= ?", options.delete(:start_at)]) if options[:start_at]
          end_at = sanitize_sql(["#{Tagging.table_name}.created_at <= ?", options.delete(:end_at)]) if options[:end_at]

          type_and_context = "#{Tagging.table_name}.taggable_type = #{quote_value(base_class.name)}"
          
          conditions = [
            type_and_context,
            options[:conditions],
            start_at,
            end_at
          ]

          conditions = conditions.compact.join(' AND ')
          conditions = merge_conditions(conditions, scope[:conditions]) if scope

          joins = ["LEFT OUTER JOIN #{Tagging.table_name} ON #{Tag.table_name}.id = #{Tagging.table_name}.tag_id"]
          joins << sanitize_sql(["AND #{Tagging.table_name}.context = ?",options.delete(:on).to_s]) unless options[:on].nil?
          joins << "LEFT OUTER JOIN #{table_name} ON #{table_name}.#{primary_key} = #{Tagging.table_name}.taggable_id"
          joins << scope[:joins] if scope && scope[:joins]

          at_least  = sanitize_sql(['COUNT(*) >= ?', options.delete(:at_least)]) if options[:at_least]
          at_most   = sanitize_sql(['COUNT(*) <= ?', options.delete(:at_most)]) if options[:at_most]
          having    = [at_least, at_most].compact.join(' AND ')
          group_by  = "#{Tag.table_name}.id, #{Tag.table_name}.name HAVING COUNT(*) > 0"
          group_by << " AND #{having}" unless having.blank?

          { :select     => "#{Tag.table_name}.id, #{Tag.table_name}.name, COUNT(*) AS count", 
            :joins      => joins.join(" "),
            :conditions => conditions,
            :group      => group_by
          }.update(options)
        end    
        
        def is_taggable?
          true
        end                
      end
    
      module InstanceMethods
        
        def tag_types
          self.class.tag_types
        end
        
        def custom_contexts
          @custom_contexts ||= []
        end
        
        def is_taggable?
          self.class.is_taggable?
        end
        
        def add_custom_context(value)
          custom_contexts << value.to_s unless custom_contexts.include?(value.to_s) or self.class.tag_types.map(&:to_s).include?(value.to_s)
        end
        
        def tag_list_on(context, owner=nil)
          var_name = "@#{context.to_s.singularize}_list"
          
          if owner.nil?
            var_sym = var_name.to_sym
            value = instance_variable_get(var_name)
          else
            var_sym = :"#{var_name}_on"
            owner_hash = instance_variable_get(var_sym)
            unless owner_hash
              owner_hash = instance_variable_set(var_sym, {})
            end
            value = owner_hash[owner]
          end
          
          return value unless value.nil?
          
          add_custom_context(context)
        
          if owner.nil?
            if self.class.caching_tag_list_on?(context) and !(cached_value = cached_tag_list_on(context, owner)).nil?
              instance_variable_set(var_sym, TagList.from(self["cached_#{var_name}"]))
            else
              instance_variable_set(var_sym, TagList.new(*tags_on(context).map(&:name)))
            end
          else
            owner_hash[owner] = TagList.new(*tags_on(context, owner).map(&:name))
          end
        end
        
        def tags_on(context, owner=nil)
          if owner
            opts = {:conditions => ["context = ? AND tagger_id = ? AND tagger_type = ?",
                                    context.to_s, owner.id, owner.class.to_s]}
          else
            opts = {:conditions => ["context = ?", context.to_s]}
          end
          base_tags.find(:all, opts)
        end
        
        def cached_tag_list_on(context)
          self["cached_#{context.to_s.singularize}_list"]
        end
        
        def set_tag_list_on(context,new_list, tagger=nil)
          instance_variable_set("@#{context.to_s.singularize}_list", TagList.from_owner(tagger, new_list))
          add_custom_context(context)
        end
        
        def tag_counts_on(context,options={})
          self.class.tag_counts_on(context,{:conditions => ["#{Tag.table_name}.name IN (?)", tag_list_on(context)]}.reverse_merge!(options))
          #self.class.tag_counts_on(context,{:conditions => ["#{self.class.table_name}.id = ?", self.id]}.reverse_merge!(options))
        end

        def related_tags_for(context, klass, options = {})
          search_conditions = related_search_options(context, klass, options)

          klass.find(:all, search_conditions)
        end

        def related_search_options(context, klass, options = {})
          tags_to_find = self.tags_on(context).collect { |t| t.name }

          { :select     => "#{klass.table_name}.*, COUNT(#{Tag.table_name}.id) AS count", 
            :from       => "#{klass.table_name}, #{Tag.table_name}, #{Tagging.table_name}",
            :conditions => ["#{klass.table_name}.id = #{Tagging.table_name}.taggable_id AND #{Tagging.table_name}.taggable_type = '#{klass.to_s}' AND #{Tagging.table_name}.tag_id = #{Tag.table_name}.id AND #{Tag.table_name}.name IN (?)", tags_to_find],
            :group      => "#{klass.table_name}.id",
            :order      => "count DESC"
          }.update(options)
        end
        
        def save_cached_tag_list
          self.class.tag_types.map(&:to_s).each do |tag_type|
            if self.class.send("caching_#{tag_type.singularize}_list?")
              self["cached_#{tag_type.singularize}_list"] = send("#{tag_type.singularize}_list").to_s
            end
          end
        end
        
        def save_tags
          (custom_contexts + self.class.tag_types.map(&:to_s)).each do |tag_type|
            next unless instance_variable_get("@#{tag_type.singularize}_list")
            owner = instance_variable_get("@#{tag_type.singularize}_list").owner
            new_tag_names = instance_variable_get("@#{tag_type.singularize}_list") - tags_on(tag_type, owner).map(&:name)
            old_tags = tags_on(tag_type, owner).reject { |tag| instance_variable_get("@#{tag_type.singularize}_list").include?(tag.name) }
          
            self.class.transaction do
              (owner.nil? ? base_tags : owner.owned_tags).delete(*old_tags) if old_tags.any?

              new_tag_names.each do |new_tag_name|
                new_tag = Tag.find_or_create_with_like_by_name(new_tag_name)
                Tagging.create(:tag_id => new_tag.id, :context => tag_type, 
                               :taggable => self, :tagger => owner)
              end
            end
          end
          
          true
        end
        
        def reload_with_tag_list(*args)
          self.class.tag_types.each do |tag_type|
            var_names = ["@#{tag_type.to_s.singularize}_list"]
            var_names.push "#{var_names.first}_on"
            var_names.each do |var_name|
              remove_instance_variable(var_name) if instance_variable_defined?(var_name)
            end
          end
          
          reload_without_tag_list(*args)
        end
      end
    end
  end
end