#
# Copyright (C) 2014 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.

require_dependency 'importers'

module Importers
  class AssignmentImporter < Importer

    self.item_class = Assignment

    def self.process_migration(data, migration)
      assignments = data['assignments'] ? data['assignments']: []
      to_import = migration.to_import 'assignments'

      create_assignments(assignments, migration)

      migration_ids = assignments.map{|m| m['assignment_id'] }.compact
      conn = Assignment.connection
      cases = []
      max = migration.context.assignments.pluck(:position).compact.max || 0
      assignments.each_with_index{|m, idx| cases << " WHEN migration_id=#{conn.quote(m['assignment_id'])} THEN #{max + idx + 1} " if m['assignment_id'] }
      unless cases.empty?
        conn.execute("UPDATE #{Assignment.quoted_table_name} SET position=CASE #{cases.join(' ')} ELSE NULL END WHERE context_id=#{migration.context.id} AND context_type=#{conn.quote(migration.context.class.to_s)} AND migration_id IN (#{migration_ids.map{|id| conn.quote(id)}.join(',')})")
      end
    end

    def self.create_assignments(assignments, migration)
      assignment_records = []
      context = migration.context

      AssignmentGroup.suspend_callbacks(:update_student_grades) do
        Assignment.suspend_callbacks(:update_submissions_later) do
          assignments.each do |assign|
            if migration.import_object?("assignments", assign['migration_id'])
              begin
                assignment_records << import_from_migration(assign, context, migration, nil, nil)
              rescue
                migration.add_import_warning(t('#migration.assignment_type', "Assignment"), assign[:title], $!)
              end
            end
          end
        end
      end

      if context.respond_to?(:assignment_group_no_drop_assignments) && context.assignment_group_no_drop_assignments
        context.assignments.active.where.not(:migration_id => nil).
          where(:assignment_group_id => context.assignment_group_no_drop_assignments.values).each do |item|
          if group = context.assignment_group_no_drop_assignments[item.migration_id]
            AssignmentGroup.add_never_drop_assignment(group, item)
          end
        end
      end

      assignment_records.compact!

      context.clear_todo_list_cache(:admins) if context.is_a?(Course)
    end

    def self.create_tool_settings(tool_setting_hash, tool_proxy, assignment)
      return if tool_proxy.blank? || tool_setting_hash.blank?

      ts_vendor_code = tool_setting_hash.dig('vendor_code')
      ts_product_code = tool_setting_hash.dig('product_code')
      ts_custom = tool_setting_hash.dig('custom')
      ts_custom_params = tool_setting_hash.dig('custom_parameters')

      return unless tool_proxy.product_family.vendor_code == ts_vendor_code &&
                    tool_proxy.product_family.product_code == ts_product_code

      tool_setting = tool_proxy.tool_settings.find_or_create_by!(
        resource_link_id: assignment.lti_context_id,
        context: assignment.course
      )

      tool_setting.update!(
        custom: ts_custom,
        custom_parameters: ts_custom_params,
        vendor_code: ts_vendor_code,
        product_code: ts_product_code
      )
    end

    def self.create_default_line_item(assignment, migration)
      assignment.create_assignment_line_item!
    rescue
      migration.add_warning(
        t('Error associating assignment "%{assignment_name}" with an LTI tool.', assignment_name: assignment.title)
      )
    end

    def self.import_from_migration(hash, context, migration, item=nil, quiz=nil)
      hash = hash.with_indifferent_access
      return nil if hash[:migration_id] && hash[:assignments_to_import] && !hash[:assignments_to_import][hash[:migration_id]]
      item ||= Assignment.where(context_type: context.class.to_s, context_id: context, id: hash[:id]).first
      item ||= Assignment.where(context_type: context.class.to_s, context_id: context, migration_id: hash[:migration_id]).first if hash[:migration_id]
      item ||= context.assignments.temp_record #new(:context => context)

      item.saved_by = :migration
      item.mark_as_importing!(migration)
      master_migration = migration&.for_master_course_import?  # propagate null dates only for blueprint syncs

      item.title = hash[:title]
      item.title = I18n.t('untitled assignment') if item.title.blank?
      item.migration_id = hash[:migration_id]
      if item.new_record? || item.deleted? || master_migration
        if item.can_unpublish?
          item.workflow_state = (hash[:workflow_state] || 'published')
        else
          item.workflow_state = 'published'
        end
      end
      if hash[:instructions_in_html] == false
        self.extend TextHelper
      end

      description = ""
      if hash[:instructions_in_html] == false
        description += migration.convert_text(hash[:description] || "")
        description += migration.convert_text(hash[:instructions] || "")
      else
        description += migration.convert_html(hash[:description] || "", :assignment, hash[:migration_id], :description)
        description += migration.convert_html(hash[:instructions] || "", :assignment, hash[:migration_id], :description)
      end
      description += Attachment.attachment_list_from_migration(context, hash[:attachment_ids])
      item.description = description

      if hash[:freeze_on_copy]
        item.freeze_on_copy = true
        item.copied = true
        item.copying = true
      end
      if !hash[:submission_types].blank?
        item.submission_types = hash[:submission_types]
      elsif ['discussion_topic'].include?(hash[:submission_format])
        item.submission_types = "discussion_topic"
      elsif ['online_upload','textwithattachments'].include?(hash[:submission_format])
        item.submission_types = "online_upload,online_text_entry"
      elsif ['online_text_entry'].include?(hash[:submission_format])
        item.submission_types = "online_text_entry"
      elsif ['webpage'].include?(hash[:submission_format])
        item.submission_types = "online_upload"
      elsif ['online_quiz'].include?(hash[:submission_format])
        item.submission_types = "online_quiz"
      elsif ['external_tool'].include?(hash[:submission_format])
        item.submission_types = "external_tool"
      end
      if item.submission_types == "online_quiz"
        item.saved_by = :quiz
      end
      if item.submission_types == "discussion_topic"
        item.saved_by = :discussion_topic
      end

      if hash[:grading_type]
        item.grading_type = hash[:grading_type]
        item.points_possible = hash[:points_possible]
      elsif grading = hash[:grading]
        hash[:due_at] ||= grading[:due_at] || grading[:due_date]
        hash[:assignment_group_migration_id] ||= grading[:assignment_group_migration_id]
        if grading[:grade_type] =~ /numeric|points/i
          item.points_possible = grading[:points_possible] ? grading[:points_possible].to_f : 10
        elsif grading[:grade_type] =~ /alphanumeric|letter_grade/i
          item.grading_type = "letter_grade"
          item.points_possible = grading[:points_possible] ? grading[:points_possible].to_f : 100
        elsif grading[:grade_type] == 'rubric'
          hash[:rubric_migration_id] ||= grading[:rubric_id]
        elsif grading[:grade_type] == 'not_graded'
          item.submission_types = 'not_graded'
        end
      end
      if hash[:assignment_group_migration_id]
        item.assignment_group = context.assignment_groups.where(migration_id: hash[:assignment_group_migration_id]).first
      end
      item.assignment_group ||= context.assignment_groups.active.where(name: t(:imported_assignments_group, "Imported Assignments")).first_or_create

      if item.points_possible.to_i < 0
        item.points_possible = 0
      end

      item.allowed_attempts = hash[:allowed_attempts] if hash[:allowed_attempts]

      if !item.new_record? && item.is_child_content? && (item.editing_restricted?(:due_dates) || item.editing_restricted?(:availability_dates))
        # is a date-restricted master course item - clear their old overrides because we're mean
        item.assignment_overrides.where.not(:set_type => AssignmentOverride::SET_TYPE_NOOP).destroy_all
      end

      item.needs_update_cached_due_dates = true if item.new_record? || item.update_cached_due_dates?
      item.save_without_broadcasting!
      # somewhere in the callstack, save! will call Quiz#update_assignment, and Rails will have helpfully
      # reloaded the quiz's assignment, so we won't know about the changes to the object (in particular,
      # workflow_state) that it did
      item.reload

      unless master_migration && migration.master_course_subscription.content_tag_for(item)&.downstream_changes&.include?("rubric")
        rubric = nil
        rubric = context.rubrics.where(migration_id: hash[:rubric_migration_id]).first if hash[:rubric_migration_id]
        rubric ||= context.available_rubric(hash[:rubric_id]) if hash[:rubric_id]
        if rubric
          assoc = rubric.associate_with(item, context, :purpose => 'grading', :skip_updating_points_possible => true)
          assoc.use_for_grading = !!hash[:rubric_use_for_grading] if hash.key?(:rubric_use_for_grading)
          assoc.hide_score_total = !!hash[:rubric_hide_score_total] if hash.key?(:rubric_hide_score_total)
          assoc.hide_points = !!hash[:rubric_hide_points] if hash.key?(:rubric_hide_points)
          assoc.hide_outcome_results = !!hash[:rubric_hide_outcome_results] if hash.key?(:rubric_hide_outcome_results)
          if hash[:saved_rubric_comments]
            assoc.summary_data ||= {}
            assoc.summary_data[:saved_comments] ||= {}
            assoc.summary_data[:saved_comments] = hash[:saved_rubric_comments]
          end
          assoc.skip_updating_points_possible = true
          assoc.save

          item.points_possible ||= rubric.points_possible if item.infer_grading_type == "points"
        elsif master_migration && item.rubric
          item.rubric_association.destroy
        end
      end

      if hash[:assignment_overrides]
        hash[:assignment_overrides].each do |o|
          override = item.assignment_overrides.where(o.slice(:set_type, :set_id)).first
          override ||= item.assignment_overrides.build
          override.set_type = o[:set_type]
          override.title = o[:title]
          override.set_id = o[:set_id]
          AssignmentOverride.overridden_dates.each do |field|
            next unless o.key?(field)
            override.send "override_#{field}", Canvas::Migration::MigratorHelper.get_utc_time_from_timestamp(o[field])
          end
          override.save!
          migration.add_imported_item(override,
            key: [item.migration_id, override.set_type, override.set_id].join('/'))
        end
        if hash.has_key?(:only_visible_to_overrides)
          item.only_visible_to_overrides = hash[:only_visible_to_overrides]
        end
      end

      if hash[:grading_standard_migration_id]
        gs = context.grading_standards.where(migration_id: hash[:grading_standard_migration_id]).first
        item.grading_standard = gs if gs
      elsif hash[:grading_standard_id] && migration
        gs = GradingStandard.for(context).where(id: hash[:grading_standard_id]).first unless migration.cross_institution?
        if gs
          item.grading_standard = gs if gs
        else
          migration.add_warning(t('errors.import.grading_standard_not_found', %{The assignment "%{title}" referenced a grading scheme that was not found in the target course's account chain.}, :title => hash[:title]))
        end
      end
      if quiz
        item.quiz = quiz
      elsif hash[:quiz_migration_id]
        if q = context.quizzes.where(migration_id: hash[:quiz_migration_id]).first
          if !item.quiz || item.quiz.id == q.id
            # the quiz is published because it has an assignment
            q.assignment = item
            q.generate_quiz_data
            q.published_at = Time.now
            q.workflow_state = 'available'
            q.save
          end
        end
        item.submission_types = 'online_quiz'
        item.saved_by = :quiz
      end

      hash[:due_at] ||= hash[:due_date] if hash.has_key?(:due_date)
      [:due_at, :lock_at, :unlock_at, :peer_reviews_due_at].each do |key|
        if hash.has_key?(key) && (master_migration || hash[key].present?)
          item.send"#{key}=", Canvas::Migration::MigratorHelper.get_utc_time_from_timestamp(hash[key])
        end
      end

      if hash[:has_group_category]
        item.group_category = context.group_categories.active.where(:name => hash[:group_category]).first
        item.group_category ||= context.group_categories.active.where(:name => t("Project Groups")).first_or_create
      end

      if hash.has_key?(:moderated_grading) && context.feature_enabled?(:moderated_grading)
        item.moderated_grading = hash[:moderated_grading]
      end
      if hash.has_key?(:anonymous_grading) && context.feature_enabled?(:anonymous_marking)
        item.anonymous_grading = hash[:anonymous_grading]
      end

      [:peer_reviews,
       :automatic_peer_reviews, :anonymous_peer_reviews,
       :grade_group_students_individually, :allowed_extensions,
       :position, :peer_review_count,
       :omit_from_final_grade, :intra_group_peer_reviews,
       :grader_count, :grader_comments_visible_to_graders,
       :graders_anonymous_to_graders, :grader_names_visible_to_final_grader,
       :anonymous_instructor_annotations
      ].each do |prop|
        item.send("#{prop}=", hash[prop]) unless hash[prop].nil?
      end

      if hash[:post_to_sis] && item.grading_type != 'not_graded' && AssignmentUtil.due_date_required_for_account?(context) &&
        (item.due_at.nil? || (migration.date_shift_options && Canvas::Plugin.value_to_boolean(migration.date_shift_options[:remove_dates])))
        # check if it's going to fail the weird post_to_sis validation requiring due dates
        # either because the date is already nil or we're going to remove it later
        migration.add_warning(
          t("The Sync to SIS setting could not be enabled for the assignment \"%{assignment_name}\" without a due date.",
            :assignment_name => item.title))
      elsif !hash[:post_to_sis].nil?
        item.post_to_sis = hash[:post_to_sis]
      end

      [:turnitin_enabled, :vericite_enabled].each do |prop|
        if !hash[prop].nil? && context.send("#{prop}?")
          item.send("#{prop}=", hash[prop])
        end
      end

      if item.turnitin_enabled || item.vericite_enabled
        settings = JSON.parse(hash[:turnitin_settings]).with_indifferent_access
        settings[:created] = false if settings[:created]
        if item.vericite_enabled
          item.vericite_settings = settings
        else
          item.turnitin_settings = settings
        end
      end

      if hash["similarity_detection_tool"].present?
        settings =  item.turnitin_settings
        settings[:originality_report_visibility] = hash["similarity_detection_tool"]["visibility"]
        item.turnitin_settings = settings
      end

      migration.add_imported_item(item)

      if migration.date_shift_options
        # Unfortunately, we save the assignment here, and then shift dates and
        # save the assignment again later in the course migration. Saving here
        # would normally schedule the auto peer reviews job with the
        # pre-shifted due date, which is probably in the past. After shifting
        # dates, it is saved again, but because the job is stranded, and
        # because the new date is probably later than the old date, the new job
        # is not scheduled, even though that's the date we want.
        item.skip_schedule_peer_reviews = true
      end
      item.needs_update_cached_due_dates = true if item.new_record? || item.update_cached_due_dates?
      item.save_without_broadcasting!
      item.skip_schedule_peer_reviews = nil

      if item.submission_types == 'external_tool' && (hash[:external_tool_url] || hash[:external_tool_id] || hash[:external_tool_migration_id])
        current_tag = item.external_tool_tag
        needs_new_tag = !current_tag ||
          (hash[:external_tool_url] && current_tag.url != hash[:external_tool_url]) ||
          (hash[:external_tool_id] && current_tag.content_id != hash[:external_tool_id].to_i) ||
          (hash[:external_tool_migration_id] && current_tag.content&.migration_id != hash[:external_tool_migration_id])

        if needs_new_tag
          tag = item.create_external_tool_tag(:url => hash[:external_tool_url], :new_tab => hash[:external_tool_new_tab])
          if hash[:external_tool_id] && migration && !migration.cross_institution?
            tool_id = hash[:external_tool_id].to_i

            # First check to see if there are any matching tools for the
            # tool URL provided in the migration hash (giving preference
            # to the tool ID provided in that same hash).
            #
            # In some cases the tool ID in the source context does not match the
            # tool ID from the destination context. This check should help find
            # a matching tool correctly.
            tool = ContextExternalTool.find_external_tool(hash[:external_tool_url], context, tool_id)

            # If no match is found in the first search, fall back on using the tool ID
            # provided in the migration hash if a tool with that ID is present
            # in the destination context.
            tool ||= ContextExternalTool.all_tools_for(context).find_by(id: tool_id)

            tag.content_id = tool&.id
          elsif hash[:external_tool_migration_id]
            tool = context.context_external_tools.where(migration_id: hash[:external_tool_migration_id]).first
            tag.content_id = tool.id if tool
          end
          if hash[:external_tool_data_json]
            tag.external_data = JSON.parse(hash[:external_tool_data_json])
          end
          tag.content_type = 'ContextExternalTool'
          if !tag.save
            if tag.errors["url"]
              migration.add_warning(t('errors.import.external_tool_url',
                "The url for the external tool assignment \"%{assignment_name}\" wasn't valid.",
                :assignment_name => item.title))
            end
            item.association(:external_tool_tag).target = nil # otherwise it will trigger destroy on the tag
          end
        end
        create_default_line_item(item, migration)
      end

      if hash["similarity_detection_tool"].present?
        similarity_tool = hash["similarity_detection_tool"]
        vendor_code = similarity_tool["vendor_code"]
        product_code = similarity_tool["product_code"]
        resource_type_code = similarity_tool["resource_type_code"]
        item.assignment_configuration_tool_lookups.find_or_create_by!(
          tool_vendor_code: vendor_code,
          tool_product_code: product_code,
          tool_resource_type_code: resource_type_code,
          tool_type: 'Lti::MessageHandler',
          context_type: context.class.name
        )
        active_proxies = Lti::ToolProxy.find_active_proxies_for_context_by_vendor_code_and_product_code(
          context: context, vendor_code: vendor_code, product_code: product_code
        )


        if active_proxies.blank?
          migration.add_warning(I18n.t(
            "We were unable to find a tool profile match for vendor_code: \"%{vendor_code}\" product_code: \"%{product_code}\".",
            vendor_code: vendor_code, product_code: product_code)
          )
        else
          item.lti_context_id ||= SecureRandom.uuid
          create_tool_settings(hash['tool_setting'], active_proxies.first, item)
        end
      end

      # Ensure anonymous and moderated assignments always start out manually
      # posted, even if the moderated assignment in the old course was switched
      # to automatically post after it had grades published
      post_manually = hash.dig(:post_policy, :post_manually) || item.anonymous_grading || item.moderated_grading
      item.post_policy.update!(post_manually: !!post_manually)

      item
    end
  end
end
