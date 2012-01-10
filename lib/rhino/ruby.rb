
module Rhino
  module Ruby
    
    def self.wrap_error(e)
      JS::WrappedException.new(org.jruby.exceptions.RaiseException.new(e))
    end
    
    # shared JS::Scriptable implementation
    module Scriptable
      
      # override Object Scriptable#get(String name, Scriptable start);
      # override Object Scriptable#get(int index, Scriptable start);
      def get(name, start)
        access.get(unwrap, name, self) { super }
      end

      # override boolean Scriptable#has(String name, Scriptable start);
      # override boolean Scriptable#has(int index, Scriptable start);
      def has(name, start)
        access.has(unwrap, name, self) { super }
      end

      # override void Scriptable#put(String name, Scriptable start, Object value);
      # override void Scriptable#put(int index, Scriptable start, Object value);
      def put(name, start, value)
        access.put(unwrap, name, value) { super }
      end
      
      # override Object[] Scriptable#getIds();
      def getIds
        ids = []
        unwrap.public_methods(false).each do |name| 
          name = name[0...-1] if name[-1, 1] == '=' # 'foo=' ... 'foo'
          name = name.to_java # java.lang.String
          ids << name unless ids.include?(name)
        end
        super.each { |id| ids.unshift(id) }
        ids.to_java
      end
      
      @@access = nil
      
      def self.access=(access)
        @@access = access
      end
      
      def self.access
        @@access ||= Ruby::DefaultAccess
      end
      
      private
      
        def access
          Scriptable.access
        end
      
    end
    
    class Object < JS::ScriptableObject
      include JS::Wrapper
      include Scriptable
      
      # wrap an arbitrary (ruby) object
      def self.wrap(object, scope = nil)
        Ruby.cache(object) { new(object, scope) }
      end

      TYPE = JS::TopLevel::Builtins::Object
      
      def initialize(object, scope)
        super()
        @ruby = object
        JS::ScriptRuntime.setBuiltinProtoAndParent(self, scope, TYPE) if scope
      end

      # abstract Object Wrapper#unwrap();
      def unwrap
        @ruby
      end

      # abstract String Scriptable#getClassName();
      def getClassName
        @ruby.class.to_s # to_s handles 'nameless' classes as well
      end

      def toString
        "[ruby #{getClassName}]" # [object User]
      end

      # protected Object ScriptableObject#equivalentValues(Object value)
      def equivalentValues(other) # JS == operator
        other.is_a?(Object) && unwrap.eql?(other.unwrap)
      end
      alias_method :'==', :equivalentValues
      
    end

    class Function < JS::BaseFunction
      include JS::Wrapper
      include Scriptable
      
      # wrap a callable (Method/Proc)
      def self.wrap(callable, scope = nil)
        # NOTE: include JS::Wrapper & Ruby.cache(callable.to_s) guarantees === 
        # in Rhino although if a bind Method gets passed it might get confusing
        Ruby.cache(callable.to_s) { new(callable, scope) }
      end

      def initialize(callable, scope)
        super()
        @callable = callable
        JS::ScriptRuntime.setFunctionProtoAndParent(self, scope) if scope
      end

      def unwrap
        @callable
      end
      
      # override int BaseFunction#getLength()
      def getLength
        arity = @callable.arity
        arity < 0 ? ( arity + 1 ).abs : arity
      end

      # #deprecated int BaseFunction#getArity()
      def getArity
        getLength
      end

      # override String BaseFunction#getFunctionName()
      def getFunctionName
        @callable.is_a?(Proc) ? "" : @callable.name
      end

      # protected Object ScriptableObject#equivalentValues(Object value)
      def equivalentValues(other) # JS == operator
        return false unless other.is_a?(Function)
        return true if unwrap == other.unwrap
        # Method.== does check if their bind to the same object
        # JS == means they might be bind to different objects :
        unwrap.to_s == other.unwrap.to_s # "#<Method: Foo#bar>"
      end
      alias_method :'==', :equivalentValues

      # override Object BaseFunction#call(Context context, Scriptable scope, 
      #                                   Scriptable thisObj, Object[] args)
      def call(context, scope, this, args)
        args = args.to_a # java.lang.Object[] -> Array
        # JS function style :
        if ( arity = @callable.arity ) != -1 # (a1, *a).arity == -2
          if arity > -1 && args.size > arity # omit 'redundant' arguments
            args = args.slice(0, arity)
          elsif arity > args.size || # fill 'missing' arguments
              ( arity < -1 && (arity = arity.abs - 1) > args.size )
            (arity - args.size).times { args.push(nil) }
          end
        end
        rb_args = Rhino.args_to_ruby(args)
        begin
          callable = 
            if @callable.is_a?(UnboundMethod)
              @callable.bind(Rhino.to_ruby(this))
            else
              @callable
            end
          result = callable.call(*rb_args)
        rescue => e
          raise Ruby.wrap_error(e) # thus `try { } catch (e)` works in JS
        end
        Rhino.to_javascript(result, scope)
      end

    end

    class Constructor < Function
      include JS::Wrapper

      # wrap a ruby class as as constructor function
      def self.wrap(klass, scope = nil)
        # NOTE: caching here seems redundant since we implemented JS::Wrapper 
        # and a ruby class objects seems always the same ref under JRuby ...
        Ruby.cache(klass) { new(klass, scope) }
      end

      def initialize(klass, scope)
        super(klass.method(:new), scope)
        @klass = klass
      end

      def unwrap
        @klass
      end

      # override int BaseFunction#getLength()
      def getLength
        arity = @klass.instance_method(:initialize).arity
        arity < 0 ? ( arity + 1 ).abs : arity
      end
      
      # override boolean Scriptable#hasInstance(Scriptable instance);
      def hasInstance(instance)
        return false unless instance
        return true if instance.is_a?(@klass)
        instance.is_a?(Object) && instance.unwrap.is_a?(@klass)
      end

    end
    
    def self.cache(key, &block)
      context = JS::Context.getCurrentContext
      context ? context.cache(key, &block) : yield
    end
    
  end
  
  RubyObject = Ruby::Object
  RubyFunction = Ruby::Function
  RubyConstructor = Ruby::Constructor
  
end
