class UrlOrFileInput < SimpleForm::Inputs::Base

  def input
    if options[:wrapper_html].present?
      options[:wrapper_html].merge!(:class => 'double_input')
    else
      options[:wrapper_html] = { :class => 'double_input' }
    end

      input_html = template.content_tag('div', :class => 'group') do
      url_input_html = template.content_tag('span', I18n.t('simple_form.custom_inputs.url_or_file_input.url'), :class => 'label')
      url_input_html += template.content_tag('span', :class => 'label_radio') do
        label_radio_html = template.radio_button_tag("#{tag_name}[input_type]", 'url')
        label_radio_html += template.label_tag("#{tag_id}_input_type_url", I18n.t('simple_form.custom_inputs.url_or_file_input.url'))
      end

      url_input_html += template.content_tag('div', :class => 'nested_input') do
        @builder.url_field(options[:url], input_html_options.merge({:placeholder => I18n.t('simple_form.custom_inputs.url_or_file_input.url_placeholder')}))
      end
    end

    input_html += template.content_tag('div', :class => 'nested_input') do
      template.content_tag('span', 'OR', :class => 'or')
    end

    input_html += template.content_tag('div', :class => 'group') do
      url_input_html = template.content_tag('span', I18n.t('simple_form.custom_inputs.url_or_file_input.file'), :class => 'label')
      url_input_html += template.content_tag('span', :class => 'label_radio') do
        label_radio_html = template.radio_button_tag("#{tag_name}[input_type]", 'file')
        label_radio_html += template.label_tag("#{tag_id}_input_type_file", I18n.t('simple_form.custom_inputs.url_or_file_input.file'))
      end

      url_input_html += template.content_tag('div', :class => 'nested_input') do
        @builder.file_field(attribute_name, input_html_options)
      end
    end
  end

  private

  # Note: The current implementation will cause issues if used with nested resources
  def tag_id
    "#{object_name}_#{attribute_name}"
  end

  # Note: The current implementation will cause issues if used with nested resources
  def tag_name
    "#{object_name}[#{attribute_name}]"
  end

end
