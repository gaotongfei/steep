module Steep
  class Source
    class LocatedAnnotation
      attr_reader :line
      attr_reader :annotation
      attr_reader :source

      def initialize(line:, source:, annotation:)
        @line = line
        @source = source
        @annotation = annotation
      end

      def ==(other)
        other.is_a?(LocatedAnnotation) &&
          other.line == line &&
          other.annotation == annotation
      end
    end

    attr_reader :path
    attr_reader :node
    attr_reader :mapping

    def initialize(path:, node:, mapping:)
      @path = path
      @node = node
      @mapping = mapping
    end

    class Builder < ::Parser::Builders::Default
      def string_value(token)
        value(token)
      end

      def emit_lambda
        true
      end
    end

    def self.parser
      ::Parser::CurrentRuby.new(Builder.new).tap do |parser|
        parser.diagnostics.all_errors_are_fatal = true
        parser.diagnostics.ignore_warnings = true
      end
    end

    def self.parse(source_code, path:, labeling: ASTUtils::Labeling.new)
      buffer = ::Parser::Source::Buffer.new(path.to_s, 1)
      buffer.source = source_code
      node = labeling.translate(parser.parse(buffer), {})

      annotations = []

      _, comments, _ = yield_self do
        buffer = ::Parser::Source::Buffer.new(path.to_s)
        buffer.source = source_code
        parser = ::Parser::CurrentRuby.new

        parser.tokenize(buffer)
      end

      buffer = AST::Buffer.new(name: path, content: source_code)

      comments.each do |comment|
        src = comment.text.gsub(/\A#/, '')
        annotation = Steep::Parser.parse_annotation_opt(src,
                                                        buffer: buffer,
                                                        offset: comment.location.expression.begin_pos+1)
        if annotation
          annotations << LocatedAnnotation.new(line: comment.location.line, source: src, annotation: annotation)
        end
      end

      mapping = {}
      construct_mapping(node: node, annotations: annotations, mapping: mapping)

      annotations.each do |annot|
        mapping[node.__id__] = [] unless mapping.key?(node.__id__)
        mapping[node.__id__] << annot.annotation
      end

      new(path: path, node: node, mapping: mapping)
    end

    def self.construct_mapping(node:, annotations:, mapping:)
      each_child_node(node) do |child|
        construct_mapping(node: child, annotations: annotations, mapping: mapping)
      end

      case node.type
      when :def, :block, :module, :class
        start_line = node.loc.line
        end_line = node.loc.last_line

        consumed = []

        annotations.each do |annot|
          if start_line <= annot.line && annot.line < end_line
            consumed << annot
            mapping[node.__id__] = [] unless mapping.key?(node.__id__)
            mapping[node.__id__] << annot.annotation
          end
        end

        consumed.each do |annot|
          annotations.delete annot
        end
      end
    end

    def self.each_child_node(node)
      node.children.each do |child|
        if child.is_a?(::AST::Node)
          yield child
        end
      end
    end

    def annotations(block:)
      AST::Annotation::Collection.new(annotations: mapping[block.__id__] || [])
    end
  end
end
