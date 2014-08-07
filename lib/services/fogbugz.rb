require 'fogbugz'
require 'sanitize'
require 'open-uri'

class AhaServices::Fogbugz < AhaService
  title 'Fogbugz'

  string :fogbugz_url, description: "URL for your FogBugz server without the trailing slash, e.g. https://bigaha.fogbugz.com"
  string :api_token, description: "API token for the FogBugz server. You can generate this token using the instructions here: http://help.fogcreek.com/8447/how-to-get-a-fogbugz-xml-api-token"

  install_button
  select :projects, collection: -> (meta_data, data) do
    meta_data.projects.sort_by(&:sProject).collect { |project| [project.sProject, project.ixProject] }
  end, description: "FogBugz project that this Aha! product should integrate with." 

  callback_url description: "Add '?case_number=\#{CaseNumber}' to this url before creating the trigger in FogBugz."


#========
# EVENTS
#========

  def receive_installed
    meta_data.projects = fogbugz_api.command(:listProjects)['projects']['project']
  end

  def receive_create_feature
    feature_case = create_or_update_case(payload.feature)
  end

  def receive_update_feature
    feature_case = create_or_update_case(payload.feature)
  end

  def receive_webhook
    fogbugz_case = fetch_case(payload.case_number)

    begin
      result = find_resource_with_case(fogbugz_case)
    rescue AhaApi::NotFound
      return # Ignore cases that we don't have Aha! features for.
    end

    if result.feature
      resource = result.feature
      resource_type = "feature"
    elsif result.requirement
      resource = result.requirement
      resource_type = "requirement"
    else
      logger.info("Unhandled resource type")
      return
    end

    update_resource(resource.resource, resource_type, fogbugz_case["sStatus"])
  end

#==============
# Api Methods
#==============

  def create_or_update_case(feature, parent_case = nil)
    old_attachments = []

    parameters = {
      sTitle: feature.name, 
      sEvent: Sanitize.fragment(feature.description.body).strip,
      sTags: feature.tags,
      ixProject: data.projects
    }

    parameters[:ixBugParent] = parent_case if parent_case

    command = :new
    if fogbugz_case = fetch_case_from_feature(feature)
      command = :edit
      parameters = set_edit_parameters(fogbugz_case, parameters)
      old_attachments = has_attachments(fogbugz_case)
    end

    attachments = feature.description.attachments.map do |attachment| 
      {:filename => attachment.file_name, :file => open(attachment.download_url)} unless old_attachments.include?(attachment.file_name)
    end

    fogbugz_case = fogbugz_api.command(command, parameters, attachments)["case"]
    integrate_resource_with_case(feature, fogbugz_case)

    if feature.requirements
      feature.requirements.each do |requirement|
        create_or_update_case(requirement, fogbugz_case["ixBug"])
      end
    end

    fogbugz_case
  end


  def set_edit_parameters(fogbugz_case, parameters)
    parameters.delete(:sTitle) if fogbugz_case["sTitle"] == parameters[:sTitle]
    parameters.delete(:sEvent) if fogbugz_case["sLatestTextSummary"] == parameters[:sEvent]
    parameters[:ixBug] = fogbugz_case['ixBug']
    parameters
  end

  def has_attachments(fogbugz_case)
    if case_attachments = fogbugz_case['events']['event']['rgAttachments']
      case_attachments = case_attachments['attachment'].is_a?(Hash) ? [case_attachments['attachment']] : case_attachments['attachment']
      case_attachments.collect {|attachment| attachment['sFileName'] }
    else
      []
    end
  end

  def fetch_case_from_feature(feature)
    case_number = get_integration_field(feature.integration_fields, 'number')
    fetch_case(case_number)
  end

  def fetch_case(case_number)
    found_case = fogbugz_api.command(:search, q: "case:#{ case_number }", cols: "sLatestTextSummary,latestEvent,tags,File1,sTitle,sStatus,ixStatus")
    puts found_case.try(:[], 'cases').try(:[], 'case')
    found_case.try(:[], 'cases').try(:[], 'case')
  end


  private

    def fogbugz_api
      @fogbugz_api ||= Fogbugz::Interface.new(token: data.api_token, uri: data.fogbugz_url) # remember to use https!
    end

    def integrate_resource_with_case(feature, fogbugz_case)
      api.create_integration_fields(reference_num_to_resource_type(feature.reference_num), feature.reference_num, self.class.service_name, 
        {number: fogbugz_case['ixBug'], url: "#{data.fogbugz_url}/f/cases/#{fogbugz_case["ixBug"]}"})
    end

    def find_resource_with_case(fogbugz_case)
      api.search_integration_fields(data.integration_id, :number, fogbugz_case["ixBug"])
    end

    def update_resource(resource, resource_type, new_state)
      api.put(resource, { resource_type => { workflow_status: { category: fogbugz_to_aha_category(new_state) } } })
    end


    def fogbugz_to_aha_category(status)
      case status
        when "Active" then "in_progress"
        when "Resolved (Fixed)" then "done"
        when "Closed (Fixed)" then "shipped"

        when "Resolved (Not Reproducible)"
        when "Resolved (Duplicate)"
        when "Resolved (Postponed)"
        when "Resolved (Won't Fix)"
        when "Resolved (By Design)"
        when "Closed (Not Reproducible)"
        when "Closed (Duplicate)"
        when "Closed (Postponed)"
        when "Closed (Won't Fix)"
        when "Closed (By Design)"
          "will_not_implement"
      end
    end

end