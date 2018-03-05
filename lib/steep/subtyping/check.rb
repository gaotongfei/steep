module Steep
  module Subtyping
    class Check
      attr_reader :builder
      attr_reader :cache

      def initialize(builder:)
        @builder = builder
        @cache = {}
      end

      def check(relation, constraints:, assumption: Set.new, trace: Trace.new)
        Steep.logger.tagged "#{relation.sub_type} <: #{relation.super_type}" do
          prefix = trace.size
          cached = cache[relation]
          if cached && constraints.empty?
            if cached.success?
              cached
            else
              cached.merge_trace(trace)
            end
          else
            if assumption.member?(relation)
              success(constraints: constraints)
            else
              trace.add(relation.sub_type, relation.super_type) do
                assumption = assumption + Set.new([relation])
                check0(relation, assumption: assumption, trace: trace, constraints: constraints).tap do |result|
                  result = result.else do |failure|
                    failure.drop(prefix)
                  end

                  Steep.logger.debug "result=#{result.class}"
                  cache[relation] = result if cacheable?(relation)
                end
              end
            end
          end
        end
      end

      def cacheable?(relation)
        relation.sub_type.free_variables.empty? && relation.super_type.free_variables.empty?
      end

      def success(constraints:)
        Result::Success.new(constraints: constraints)
      end

      def failure(error:, trace:)
        Result::Failure.new(error: error, trace: trace)
      end

      def check0(relation, assumption:, trace:, constraints:)
        case
        when same_type?(relation, assumption: assumption)
          success(constraints: constraints)

        when relation.sub_type.is_a?(AST::Types::Any) || relation.super_type.is_a?(AST::Types::Any)
          success(constraints: constraints)

        when relation.super_type.is_a?(AST::Types::Var)
          if constraints.domain?(relation.super_type.name)
            constraints.add(relation.super_type.name, sub_type: relation.sub_type)
            success(constraints: constraints)
          else
            failure(error: Result::Failure::UnknownPairError.new(relation: relation),
                    trace: trace)
          end

        when relation.sub_type.is_a?(AST::Types::Var)
          if constraints.domain?(relation.sub_type.name)
            constraints.add(relation.sub_type.name, super_type: relation.super_type)
            success(constraints: constraints)
          else
            failure(error: Result::Failure::UnknownPairError.new(relation: relation),
                    trace: trace)
          end

        when relation.sub_type.is_a?(AST::Types::Union)
          results = relation.sub_type.types.map do |sub_type|
            check0(Relation.new(sub_type: sub_type, super_type: relation.super_type),
                   assumption: assumption,
                   trace: trace,
                   constraints: constraints)
          end

          if results.all?(&:success?)
            results.first
          else
            results.find(&:failure?)
          end

        when relation.super_type.is_a?(AST::Types::Union)
          results = relation.super_type.types.map do |super_type|
            check0(Relation.new(sub_type: relation.sub_type, super_type: super_type),
                   assumption: assumption,
                   trace: trace,
                   constraints: constraints)
          end

          results.find(&:success?) || results.first

        when relation.sub_type.is_a?(AST::Types::Intersection)
          results = relation.sub_type.types.map do |sub_type|
            check0(Relation.new(sub_type: sub_type, super_type: relation.super_type),
                   assumption: assumption,
                   trace: trace,
                   constraints: constraints)
          end

          results.find(&:success?) || results.first

        when relation.super_type.is_a?(AST::Types::Intersection)
          results = relation.super_type.types.map do |super_type|
            check0(Relation.new(sub_type: relation.sub_type, super_type: super_type),
                   assumption: assumption,
                   trace: trace,
                   constraints: constraints)
          end

          if results.all?(&:success?)
            results.first
          else
            results.find(&:failure?)
          end

        when relation.sub_type.is_a?(AST::Types::Name) && relation.super_type.is_a?(AST::Types::Name)
          if relation.sub_type.name == relation.super_type.name
            subst = Interface::Substitution.empty

            relation.sub_type.args.zip(relation.super_type.args).each do |(sub, sup)|
              case
              when sub.is_a?(AST::Types::Var) && constraints.domain?(sub.name)
                subst.add!(sub.name, sup)
                constraints.add(sub.name, sub_type: sup, super_type: sup)
              when sup.is_a?(AST::Types::Var) && constraints.domain?(sup.name)
                subst.add!(sup.name, sub)
                constraints.add(sup.name, sub_type: sub, super_type: sub)
              end
            end

            check0(Relation.new(sub_type: relation.sub_type.subst(subst), super_type: relation.super_type.subst(subst)),
                   assumption: assumption,
                   trace: trace,
                   constraints: constraints)
          else
            sub_interface = resolve(relation.sub_type)
            super_interface = resolve(relation.super_type)

            check_interface(sub_interface, super_interface, assumption: assumption, trace: trace, constraints: constraints)
          end

        else
          failure(error: Result::Failure::UnknownPairError.new(relation: relation),
                  trace: trace)
        end
      end

      def same_type?(relation, assumption:)
        if assumption.include?(relation) && assumption.include?(relation.flip)
          return true
        end

        case
        when relation.sub_type == relation.super_type
          true
        when relation.sub_type.is_a?(AST::Types::Name) && relation.super_type.is_a?(AST::Types::Name)
          return false unless relation.sub_type.name == relation.super_type.name
          return false unless relation.sub_type.args.size == relation.super_type.args.size
          relation.sub_type.args.zip(relation.super_type.args).all? do |(s, t)|
            same_type?(Relation.new(sub_type: s, super_type: t), assumption: assumption)
          end
        else
          false
        end
      end

      def check_interface(sub_type, super_type, assumption:, trace:, constraints:)
        method_pairs = []

        super_type.methods.each do |name, sup_method|
          sub_method = sub_type.methods[name]

          if sub_method
            method_pairs << [sub_method, sup_method]
          else
            return failure(error: Result::Failure::MethodMissingError.new(name: name),
                           trace: trace)
          end
        end

        method_pairs.each do |(sub_method, sup_method)|
          result = check_method(sub_method.name, sub_method, sup_method, assumption: assumption, trace: trace, constraints: constraints)
          return result if result.failure?
        end

        success(constraints: constraints)
      end

      def check_method(name, sub_method, super_method, assumption:, trace:, constraints:)
        trace.add(sub_method, super_method) do
          all_results = super_method.types.map do |super_type|
            sub_method.types.map do |sub_type|
              trace.add(sub_type, super_type) do
                case
                when super_type.type_params.empty? && sub_type.type_params.empty?
                  check_method_type(name,
                                    sub_type,
                                    super_type,
                                    assumption: assumption,
                                    trace: trace,
                                    constraints: constraints)

                when super_type.type_params.empty?
                  yield_self do
                    sub_args = sub_type.type_params.map {|x| AST::Types::Var.fresh(x) }
                    sub_type = sub_type.instantiate(Interface::Substitution.build(sub_type.type_params,
                                                                                  sub_args))

                    match_method_type(name, sub_type, super_type, trace: trace).yield_self do |pairs|
                      case pairs
                      when Array
                        subst = pairs.each.with_object(Interface::Substitution.empty) do |(sub, sup), subst|
                          case
                          when sub.is_a?(AST::Types::Var) && sub_args.include?(sub)
                            subst.add!(sub.name, sup)
                          when sup.is_a?(AST::Types::Var) && sub_args.include?(sup)
                            subst.add!(sup.name, sub)
                          end
                        end

                        check_method_type(name,
                                          sub_type.subst(subst),
                                          super_type,
                                          assumption: assumption,
                                          trace: trace,
                                          constraints: constraints)
                      else
                        pairs
                      end
                    end
                  end

                when super_type.type_params.size == sub_type.type_params.size
                  yield_self do
                    args = sub_type.type_params.map {|x| AST::Types::Var.fresh(x) }

                    sub_type = sub_type.instantiate(Interface::Substitution.build(sub_type.type_params,
                                                                                  args))
                    super_type = super_type.instantiate(Interface::Substitution.build(super_type.type_params,
                                                                                      args))

                    check_method_type(name,
                                      sub_type,
                                      super_type,
                                      assumption: assumption,
                                      trace: trace,
                                      constraints: constraints)
                  end
                else
                  failure(error: Result::Failure::PolyMethodSubtyping.new(name: name),
                          trace: trace)
                end
              end
            end
          end

          all_results.each do |results|
            if results.any?(&:success?)
              #ok
            else
              return results.find(&:failure?)
            end
          end

          success(constraints: constraints)
        end
      end

      def check_method_type(name, sub_type, super_type, assumption:, trace:, constraints:)
        check_method_params(name, sub_type.params, super_type.params, assumption: assumption, trace: trace, constraints: constraints).then do
          check_block_given(name, sub_type.block, super_type.block, trace: trace, constraints: constraints).then do
            check_block_params(name, sub_type.block, super_type.block, assumption: assumption, trace: trace, constraints: constraints).then do
              check_block_return(sub_type.block, super_type.block, assumption: assumption, trace: trace, constraints:constraints).then do
                relation = Relation.new(super_type: super_type.return_type,
                                            sub_type: sub_type.return_type)
                check(relation, assumption: assumption, trace: trace, constraints: constraints)
              end
            end
          end
        end
      end

      def check_block_given(name, sub_block, super_block, trace:, constraints:)
        case
        when !super_block && !sub_block
          success(constraints: constraints)
        when super_block && sub_block
          success(constraints: constraints)
        else
          failure(
            error: Result::Failure::BlockMismatchError.new(name: name),
            trace: trace
          )
        end
      end

      def check_method_params(name, sub_params, super_params, assumption:, trace:, constraints:)
        match_params(name, sub_params, super_params, trace: trace).yield_self do |pairs|
          case pairs
          when Array
            pairs.each do |(sub_type, super_type)|
              relation = Relation.new(super_type: sub_type, sub_type: super_type)

              result = check(relation, assumption: assumption, trace: trace, constraints: constraints)
              return result if result.failure?
            end

            success(constraints: constraints)
          else
            pairs
          end
        end
      end

      def match_method_type(name, sub_type, super_type, trace:)
        [].tap do |pairs|
          match_params(name, sub_type.params, super_type.params, trace: trace).yield_self do |result|
            return result unless result.is_a?(Array)
            pairs.push(*result)
            pairs.push [sub_type.return_type, super_type.return_type]

            case
            when !super_type.block && !sub_type.block
              # No block required and given

            when super_type.block && sub_type.block
              match_params(name, super_type.block.params, sub_type.block.params, trace: trace).yield_self do |block_result|
                return block_result unless block_result.is_a?(Array)
                pairs.push(*block_result)
                pairs.push [super_type.block.return_type, sub_type.block.return_type]
              end

            else
              return failure(error: Result::Failure::BlockMismatchError.new(name: name),
                             trace: trace)
            end
          end
        end
      end

      def match_params(name, sub_params, super_params, trace:)
        pairs = []

        sub_flat = sub_params.flat_unnamed_params
        sup_flat = super_params.flat_unnamed_params

        failure = failure(error: Result::Failure::ParameterMismatchError.new(name: name),
                          trace: trace)

        case
        when super_params.rest
          return failure unless sub_params.rest

          while sub_flat.size > 0
            sub_type = sub_flat.shift
            sup_type = sup_flat.shift

            if sup_type
              pairs << [sub_type.last, sup_type.last]
            else
              pairs << [sub_type.last, super_params.rest]
            end
          end

          if sub_params.rest
            pairs << [sub_params.rest, super_params.rest]
          end

        when sub_params.rest
          while sub_flat.size > 0
            sub_type = sub_flat.shift
            sup_type = sup_flat.shift

            if sup_type
              pairs << [sub_type.last, sup_type.last]
            else
              break
            end
          end

          if sub_params.rest && !sup_flat.empty?
            sup_flat.each do |sup_type|
              pairs << [sub_params.rest, sup_type.last]
            end
          end
        when sub_params.required.size + sub_params.optional.size >= super_params.required.size + super_params.optional.size
          while sub_flat.size > 0
            sub_type = sub_flat.shift
            sup_type = sup_flat.shift

            if sup_type
              pairs << [sub_type.last, sup_type.last]
            else
              if sub_type.first == :required
                return failure
              else
                break
              end
            end
          end
        else
          return failure
        end

        sub_flat_kws = sub_params.flat_keywords
        sup_flat_kws = super_params.flat_keywords

        sup_flat_kws.each do |name, _|
          if sub_flat_kws.key?(name)
            pairs << [sub_flat_kws[name], sup_flat_kws[name]]
          else
            if sub_params.rest_keywords
              pairs << [sub_params.rest_keywords, sup_flat_kws[name]]
            else
              return failure
            end
          end
        end

        sub_params.required_keywords.each do |name, _|
          unless super_params.required_keywords.key?(name)
            return failure
          end
        end

        if sub_params.rest_keywords && super_params.rest_keywords
          pairs << [sub_params.rest_keywords, super_params.rest_keywords]
        end

        pairs
      end

      def check_block_params(name, sub_block, super_block, assumption:, trace:, constraints:)
        if sub_block
          check_method_params(name,
                              super_block.params,
                              sub_block.params,
                              assumption: assumption,
                              trace: trace,
                              constraints: constraints)
        else
          success(constraints: constraints)
        end
      end

      def check_block_return(sub_block, super_block, assumption:, trace:, constraints:)
        if sub_block
          relation = Relation.new(sub_type: super_block.return_type,
                                      super_type: sub_block.return_type)
          check(relation, assumption: assumption, trace: trace, constraints: constraints)
        else
          success(constraints: constraints)
        end
      end

      def module_type(type)
        case
        when builder.signatures.class?(type.name)
          type.class_type(constructor: nil)
        when builder.signatures.module?(type.name)
          type.module_type
        end
      end

      def compact(types)
        types = types.reject {|type| type.is_a?(AST::Types::Any) }

        if types.empty?
          [AST::Types::Any.new]
        else
          compact0(types)
        end
      end

      def compact0(types)
        if types.size == 1
          types
        else
          type, *types_ = types
          compacted = compact0(types_)
          compacted.flat_map do |type_|
            case
            when type == type_
              [type]
            when check(Relation.new(sub_type: type_, super_type: type), constraints: Constraints.empty).success?
              [type]
            when check(Relation.new(sub_type: type, super_type: type_), constraints: Constraints.empty).success?
              [type_]
            else
              [type, type_]
            end
          end.uniq
        end
      end

      def resolve(type, self_type: type, instance_type: nil, module_type: nil)
        case type
        when AST::Types::Any, AST::Types::Var, AST::Types::Class, AST::Types::Instance
          raise "Cannot resolve type to interface: #{type}"
        when AST::Types::Name
          builder.build(type.name).instantiate(
            type: self_type,
            args: type.args,
            instance_type: instance_type || type.instance_type,
            module_type: module_type || module_type(type)
          )
        when AST::Types::Union
          interfaces = type.types.map do |member_type|
            fresh = AST::Types::Var.fresh(:___)

            resolve(member_type, self_type: type, instance_type: fresh, module_type: fresh).select_method_type do |method_type|
              !method_type.each_type.include?(fresh)
            end
          end

          methods = interfaces.inject(nil) do |methods, i|
            if methods
              intersection = {}
              i.methods.each do |name, method|
                if methods.key?(name)
                  case
                  when method == methods[name]
                    intersection[name] = method
                  when check_method(name, method, methods[name],
                                    assumption: Set.new,
                                    trace: Trace.new,
                                    constraints: Constraints.empty).success?
                    intersection[name] = methods[name]
                  when check_method(name, methods[name], method,
                                    assumption: Set.new,
                                    trace: Trace.new,
                                    constraints: Constraints.empty).success?
                    intersection[name] = method
                  end
                end
              end
              intersection
            else
              i.methods
            end
          end

          Interface::Instantiated.new(type: type,
                                      methods: methods,
                                      ivars: {})

        when AST::Types::Intersection
          interfaces = type.types.map do |type| resolve(type) end

          methods = interfaces.inject(nil) do |methods, i|
            if methods
              i.methods.each do |name, method|
                if methods.key?(name)
                  case
                  when method == methods[name]
                  when check_method(name, method, methods[name],
                                    assumption: Set.new,
                                    trace: Trace.new,
                                    constraints: Constraints.empty).success?
                    methods[name] = method
                  when check_method(name, methods[name], method,
                                    assumption: Set.new,
                                    trace: Trace.new,
                                    constraints: Constraints.empty).success?
                    methods[name] = methods[name]
                  else
                    methods[name] = Interface::Method.new(
                      type_name: nil,
                      name: name,
                      types: methods[name].types + method.types,
                      super_method: nil,
                      attributes: []
                    )
                  end
                else
                  methods[name] = i.methods[name]
                end
              end
              methods
            else
              i.methods
            end
          end

          Interface::Instantiated.new(type: type,
                                      methods: methods,
                                      ivars: {})
        end
      end
    end
  end
end
