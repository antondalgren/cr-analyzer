require "json"

module JSON
  module Serializable
    macro included
      def initialize(*, __pull_for_json_serializable pull : ::JSON::PullParser)
        {% verbatim do %}
          {% begin %}
            {% properties = {} of Nil => Nil %}
            {% nested_groups = {} of Nil => Nil %}

            {% for ivar in @type.instance_vars %}
              {% ann = ivar.annotation(::JSON::Field) %}
              {% unless ann && (ann[:ignore] || ann[:ignore_deserialize]) %}
                {%
                  nested_key = ann && ann[:nested]
                  properties[ivar.id] = {
                    key:         ((ann && ann[:key]) || ivar).id.stringify,
                    has_default: ivar.has_default_value?,
                    default:     ivar.default_value,
                    nilable:     ivar.type.nilable?,
                    nested:      nested_key,
                    root:        ann && ann[:root],
                    converter:   ann && ann[:converter],
                    presence:    ann && ann[:presence],
                  }

                  # Group properties by nested key
                  if nested_key
                    unless nested_groups[nested_key]
                      nested_groups[nested_key] = [] of Nil
                    end
                    nested_groups[nested_key] = nested_groups[nested_key] + [ivar.id]
                  end
                %}
              {% end %}
            {% end %}

            # `%var`'s type must be exact to avoid type inference issues with
            # recursively defined serializable types
            {% for name, value in properties %}
              %var{name} = uninitialized ::Union(typeof(@{{ name }}))
              %found{name} = false
            {% end %}

            %location = pull.location
            begin
              pull.read_begin_object
            rescue exc : ::JSON::ParseException
              raise ::JSON::SerializableError.new(exc.message, self.class.to_s, nil, *%location, exc)
            end
            until pull.kind.end_object?
              %key_location = pull.location
              key = pull.read_object_key
              case key

              # Handle nested keys (groups of properties)
              {% for nested_key, field_names in nested_groups %}
                when {{nested_key}}
                  begin
                    if pull.read_null?
                      {% for field_name in field_names %}
                        {% prop = properties[field_name] %}
                        {% if prop[:nilable] %}
                          %var{field_name} = nil
                          %found{field_name} = true
                        {% end %}
                      {% end %}
                      next
                    end

                    pull.read_begin_object
                  rescue exc : ::JSON::ParseException
                    raise ::JSON::SerializableError.new(exc.message, self.class.to_s, {{nested_key}}, *%key_location, exc)
                  end

                  until pull.kind.end_object?
                    %nested_key_location = pull.location
                    nested_key = pull.read_object_key
                    case nested_key
                    {% for field_name in field_names %}
                      {% value = properties[field_name] %}
                      when {{value[:key]}}
                        begin
                          {% if value[:has_default] || value[:nilable] %}
                            if pull.read_null?
                              {% if value[:nilable] %}
                                %var{field_name} = nil
                                %found{field_name} = true
                              {% end %}
                              next
                            end
                          {% end %}

                          %var{field_name} =
                            {% if value[:converter] %}
                              {{value[:converter]}}.from_json(pull)
                            {% else %}
                              ::Union(typeof(@{{ field_name }})).new(pull)
                            {% end %}
                          %found{field_name} = true
                        rescue exc : ::JSON::ParseException
                          raise ::JSON::SerializableError.new(exc.message, self.class.to_s, {{value[:key]}}, *%nested_key_location, exc)
                        end
                    {% end %}
                    else
                      on_unknown_json_attribute(pull, nested_key, %nested_key_location)
                    end
                  end
                  pull.read_next
              {% end %}

              # Handle regular properties (without nested)
              {% for name, value in properties %}
                {% unless value[:nested] %}
                  when {{value[:key]}}
                    begin
                      {% if value[:has_default] || value[:nilable] || value[:root] %}
                        if pull.read_null?
                          {% if value[:nilable] %}
                            %var{name} = nil
                            %found{name} = true
                          {% end %}
                          next
                        end
                      {% end %}

                      %var{name} =
                        {% if value[:root] %} pull.on_key!({{value[:root]}}) do {% else %} begin {% end %}
                          {% if value[:converter] %}
                            {{value[:converter]}}.from_json(pull)
                          {% else %}
                            ::Union(typeof(@{{ name }})).new(pull)
                          {% end %}
                        end
                      %found{name} = true
                    rescue exc : ::JSON::ParseException
                      raise ::JSON::SerializableError.new(exc.message, self.class.to_s, {{value[:key]}}, *%key_location, exc)
                    end
                {% end %}
              {% end %}
              else
                on_unknown_json_attribute(pull, key, %key_location)
              end
            end
            pull.read_next

            {% for name, value in properties %}
              if %found{name}
                @{{name}} = %var{name}
              else
                {% unless value[:has_default] || value[:nilable] %}
                  raise ::JSON::SerializableError.new("Missing JSON attribute: {{value[:key].id}}", self.class.to_s, nil, *%location, nil)
                {% end %}
              end

              {% if value[:presence] %}
                @{{name}}_present = %found{name}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
        after_initialize
      end
    end

    protected def on_to_json(json : ::JSON::Builder)
    end

    def to_json(json : ::JSON::Builder)
      {% begin %}
        {% options = @type.annotation(::JSON::Serializable::Options) %}
        {% emit_nulls = options && options[:emit_nulls] %}

        {% properties = {} of Nil => Nil %}
        {% nested_groups = {} of Nil => Nil %}
        {% for ivar in @type.instance_vars %}
          {% ann = ivar.annotation(::JSON::Field) %}
          {% unless ann && (ann[:ignore] || ann[:ignore_serialize] == true) %}
            {%
              nested_key = ann && ann[:nested]
              properties[ivar.id] = {
                key:              ((ann && ann[:key]) || ivar).id.stringify,
                nested:           nested_key,
                root:             ann && ann[:root],
                converter:        ann && ann[:converter],
                emit_null:        (ann && (ann[:emit_null] != nil) ? ann[:emit_null] : emit_nulls),
                ignore_serialize: ann && ann[:ignore_serialize],
              }

              # Group properties by nested key
              if nested_key
                unless nested_groups[nested_key]
                  nested_groups[nested_key] = [] of Nil
                end
                nested_groups[nested_key] = nested_groups[nested_key] + [ivar.id]
              end
            %}
          {% end %}
        {% end %}

        json.object do
          # First, serialize nested groups
          {% for nested_key, field_names in nested_groups %}
            json.field({{nested_key}}) do
              json.object do
                {% for field_name in field_names %}
                  {% value = properties[field_name] %}
                  _{{field_name}} = @{{field_name}}

                  {% if value[:ignore_serialize] %}
                    unless {{ value[:ignore_serialize] }}
                  {% end %}

                    {% unless value[:emit_null] %}
                      unless _{{field_name}}.nil?
                    {% end %}

                      json.field({{value[:key]}}) do
                        {% if value[:converter] %}
                          if _{{field_name}}
                            {{ value[:converter] }}.to_json(_{{field_name}}, json)
                          else
                            nil.to_json(json)
                          end
                        {% else %}
                          _{{field_name}}.to_json(json)
                        {% end %}
                      end

                    {% unless value[:emit_null] %}
                      end
                    {% end %}
                  {% if value[:ignore_serialize] %}
                    end
                  {% end %}
                {% end %}
              end
            end
          {% end %}

          # Then, serialize regular properties (without nested)
          {% for name, value in properties %}
            {% unless value[:nested] %}
              _{{name}} = @{{name}}

              {% if value[:ignore_serialize] %}
                unless {{ value[:ignore_serialize] }}
              {% end %}

                {% unless value[:emit_null] %}
                  unless _{{name}}.nil?
                {% end %}

                  json.field({{value[:key]}}) do
                    {% if value[:root] %}
                      {% if value[:emit_null] %}
                        if _{{name}}.nil?
                          nil.to_json(json)
                        else
                      {% end %}

                      json.object do
                        json.field({{value[:root]}}) do
                    {% end %}

                    {% if value[:converter] %}
                      if _{{name}}
                        {{ value[:converter] }}.to_json(_{{name}}, json)
                      else
                        nil.to_json(json)
                      end
                    {% else %}
                      _{{name}}.to_json(json)
                    {% end %}

                    {% if value[:root] %}
                      {% if value[:emit_null] %}
                        end
                      {% end %}
                        end
                      end
                    {% end %}
                  end

                {% unless value[:emit_null] %}
                  end
                {% end %}
              {% if value[:ignore_serialize] %}
                end
              {% end %}
            {% end %}
          {% end %}
          on_to_json(json)
        end
      {% end %}
    end
  end
end
