class PivotalTrackerFeatureAndRequirementMappingResource < PivotalTrackerResource

  def create_feature_or_requirement(project_id, story)
    prepare_request
    response = http_post("#{api_url}/projects/#{project_id}/stories", story.to_json)

    process_response(response, 200) do |created_story|
      logger.info("Created story #{created_story.id}")
      return created_story
    end
  end

private

  def mapping
    @service.data.mapping
  end
end
