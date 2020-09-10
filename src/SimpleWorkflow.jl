module SimpleWorkflow

using Dates: unix2datetime, format
using Distributed: Future, @spawn
using UUIDs: UUID, uuid4

export ExternalAtomicJob
export getstatus,
    ispending, isrunning, issucceeded, isfailed, isinterrupted, starttime, stoptime, elapsed

abstract type JobStatus end
struct Pending <: JobStatus end
struct Running <: JobStatus end
abstract type Exited <: JobStatus end
struct Succeeded <: Exited end
struct Failed <: Exited end
struct Interrupted <: Exited end

mutable struct Timer
    start::Float64
    stop::Float64
    Timer() = new()
end

mutable struct Logger
    out::String
    err::String
end

mutable struct JobRef
    status::JobStatus
    ref::Future
    JobRef() = new(Pending())
end

abstract type Job end
abstract type AtomicJob <: Job end
struct ExternalAtomicJob <: AtomicJob
    cmd
    name::String
    id::UUID
    ref::JobRef
    timer::Timer
    log::Logger
    ExternalAtomicJob(cmd, name = "Unnamed") =
        new(cmd, name, uuid4(), JobRef(), Timer(), Logger("", ""))
end

function Base.run(x::ExternalAtomicJob)
    out = Pipe()
    err = Pipe()
    x.ref.ref = @spawn begin
        x.ref.status = Running()
        x.timer.start = time()
        ref = try
            run(pipeline(x.cmd, stdin = devnull, stdout = out, stderr = err))
        catch e
            @warn("could not spawn $(x.cmd)!")
            e
        finally
            x.timer.stop = time()
            close(out.in)
            close(err.in)
        end
        if ref isa Exception  # Include all cases?
            if ref isa InterruptException
                x.ref.status = Interrupted()
            else
                x.ref.status = Failed()
            end
            x.log.err = String(read(err))
        else
            x.ref.status = Succeeded()
            x.log.out = String(read(out))
        end
        ref
    end
    return x
end

Base.:(==)(a::Job, b::Job) = false
Base.:(==)(a::T, b::T) where {T<:Job} = a.id == b.id

getstatus(x::AtomicJob) = x.ref.status

ispending(x::AtomicJob) = getstatus(x) isa Pending

isrunning(x::AtomicJob) = getstatus(x) isa Running

issucceeded(x::AtomicJob) = getstatus(x) isa Succeeded

isfailed(x::AtomicJob) = getstatus(x) isa Failed

isinterrupted(x::AtomicJob) = getstatus(x) isa Interrupted

starttime(x::AtomicJob) = unix2datetime(x.timer.start)

stoptime(x::AtomicJob) = isrunning(x) ? nothing : unix2datetime(x.timer.stop)

elapsed(x::AtomicJob) = (isrunning(x) ? time() : x.timer.stop) - x.timer.start

function Base.show(io::IO, job::AtomicJob)
    printstyled(io, " ", job.cmd; bold = true)
    if !ispending(job)
        print(
            io,
            " from ",
            format(starttime(job), "HH:MM:SS u dd, yyyy"),
            isrunning(job) ? ", still running..." :
            ", to " * format(stoptime(job), "HH:MM:SS u dd, yyyy"),
            ", uses ",
            elapsed(job),
            " seconds.",
        )
    else
        print(" pending...")
    end
end

end
