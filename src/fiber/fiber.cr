@[NoInline]
fun get_stack_top : Void*
  dummy :: Int32
  pointerof(dummy) as Void*
end

class Fiber
  STACK_SIZE = 8 * 1024 * 1024

  @@first_fiber = nil
  @@last_fiber = nil
  @@stack_pool = [] of Void*

  protected property :stack_top
  protected property :stack_bottom
  protected property :next_fiber
  protected property :prev_fiber

  def initialize(&@proc)
    @stack = Fiber.allocate_stack
    @stack_top = @stack_bottom = @stack + STACK_SIZE
    fiber_main = ->(f : Void*) { (f as Fiber).run }

    stack_ptr = @stack + STACK_SIZE - sizeof(UInt64)
    stack_ptr = Pointer(UInt64).new(stack_ptr.address & ~0x0f_u64)
    @stack_top = (stack_ptr - 7) as Void*

    stack_ptr[0] = fiber_main.pointer.address
    stack_ptr[-1] = self.object_id.to_u64

    @prev_fiber = nil
    if last_fiber = @@last_fiber
      @prev_fiber = last_fiber
      last_fiber.next_fiber = @@last_fiber = self
    else
      @@first_fiber = @@last_fiber = self
    end
  end

  def initialize
    @proc = ->{}
    @stack = Pointer(Void).null
    @stack_top = get_stack_top
    @stack_bottom = LibGC.stackbottom

    @@first_fiber = @@last_fiber = self
  end

  protected def self.allocate_stack
    @@stack_pool.pop? || LibC.mmap(nil, Fiber::STACK_SIZE,
      LibC::PROT_READ | LibC::PROT_WRITE,
      LibC::MAP_PRIVATE | LibC::MAP_ANON,
      -1, LibC::SSizeT.new(0)).tap do |pointer|
      raise Errno.new("Cannot allocate new fiber stack") if pointer == LibC::MAP_FAILED
    end
  end

  def self.stack_pool_collect
    return if @@stack_pool.size == 0
    free_count = @@stack_pool.size > 1 ? @@stack_pool.size / 2 : 1
    free_count.times do
      stack = @@stack_pool.pop
      LibC.munmap(stack, Fiber::STACK_SIZE)
    end
  end

  def run
    @proc.call
    @@stack_pool << @stack

    # Remove the current fiber from the linked list

    if prev_fiber = @prev_fiber
      prev_fiber.next_fiber = @next_fiber
    else
      @@first_fiber = @next_fiber
    end

    if next_fiber = @next_fiber
      next_fiber.prev_fiber = @prev_fiber
    else
      @@last_fiber = @prev_fiber
    end

    # Delete the resume event if it was used by `yield` or `sleep`
    if event = @resume_event
      event.free
    end

    Scheduler.reschedule
  end

  protected def stack_top_ptr
    pointerof(@stack_top)
  end

  @[NoInline]
  @[Naked]
  protected def self.switch_stacks(current, to)
    asm (%(
      pushq %rdi
      pushq %rbx
      pushq %rbp
      pushq %r12
      pushq %r13
      pushq %r14
      pushq %r15
      movq %rsp, ($0)
      movq $1, %rsp
      popq %r15
      popq %r14
      popq %r13
      popq %r12
      popq %rbp
      popq %rbx
      popq %rdi)
    :: "r"(current), "r"(to))
  end

  def resume
    current, @@current = @@current, self
    LibGC.stackbottom = @@current.stack_bottom
    Fiber.switch_stacks(current.stack_top_ptr, @stack_top)
  end

  def sleep(time)
    event = @resume_event ||= Scheduler.create_resume_event(self)
    event.add(time)
    Scheduler.reschedule
  end

  def yield
    sleep(0)
  end

  def self.sleep(time)
    Fiber.current.sleep(time)
  end

  def self.yield
    Fiber.current.yield
  end

  protected def push_gc_roots
    # Push the used section of the stack
    LibGC.push_all_eager @stack_top, @stack_bottom
  end

  @@root = new

  def self.root
    @@root
  end

  @[ThreadLocal]
  @@current = root

  def self.current
    @@current
  end

  @@prev_push_other_roots = LibGC.get_push_other_roots

  # This will push all fibers stacks whenever the GC wants to collect some memory
  LibGC.set_push_other_roots -> do
    @@prev_push_other_roots.call

    fiber = @@first_fiber
    while fiber
      fiber.push_gc_roots unless fiber == @@current
      fiber = fiber.next_fiber
    end
  end


end
