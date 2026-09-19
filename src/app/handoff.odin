package main

// Handing a job to one worker thread and taking it back.
//
// Both of the tool's background jobs are the same shape: the geometry rebuild
// (rebuild.odin) and the upload (upload.odin). One enum, because they obey one
// rule and it is written down once here.
//
// The rule: `state` is the whole handshake, and there is no lock. At no point
// do both threads own the job, so whichever thread owns it may read and write
// every field of it freely, and the other may touch none of them. Ownership
// moves on the atomic store and nowhere else.
//
//     Idle    -> Running   the main thread has filled the job in and let go
//     Running -> Done      the worker has finished and let go
//     Done    -> Idle      the main thread has taken the result out
//
// Read `state` with sync.atomic_load and write it with sync.atomic_store. A
// plain read is a race, whatever the compiler makes of it today.

Handoff_State :: enum u8 {
	Idle,    // the main thread owns the job
	Running, // the worker owns it
	Done,    // the main thread owns it again, with a result in it
}
