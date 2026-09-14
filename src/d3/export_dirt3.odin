package d3

import "core:fmt"
import "core:os"
import "core:path/filepath"

d3_collision_build :: proc(collision:[]Collision_Triangle,allocator:=context.allocator) -> (data:[]u8,msg:string,ok:bool) {
	if len(collision)==0 { return nil,"Dirt 3 export needs collision triangles",false }
	profile,profile_msg,profile_ok:=d3_profile_builtin(); if !profile_ok { return nil,profile_msg,false }
	input:=make([]D3_Write_Tri,len(collision),context.temp_allocator)
	for triangle,i in collision {
		input[i]={p=triangle.Points,mat=profile.collision[triangle.Material]}
	}
	return d3_track_write(input,allocator)
}

// Every Dirt 3 file lands directly in `job.Out`, which the caller has already
// made. A route directory *is* the output directory when installing.
d3_out_dir :: proc(job:^Export_Job) -> (dir:string,msg:string,ok:bool) {
	if job.Out=="" { return "","export has no output directory",false }
	if err:=os.make_directory_all(job.Out); err!=nil && err!=os.General_Error.Exist { return "",fmt.tprintf("could not create %s: %v",job.Out,err),false }
	return job.Out,"",true
}

// Copy `path` to `path.orig` before it is overwritten, once. An existing `.orig`
// is the stock file and is never touched again: a second export would otherwise
// save our own previous output as the thing to revert to.
d3_backup_once :: proc(path:string) -> (msg:string,ok:bool) {
	saved:=fmt.tprintf("%s.orig",path)
	if !os.exists(path) || os.exists(saved) { return "",true }
	data,read_err:=os.read_entire_file(path,context.temp_allocator)
	if read_err!=nil { return fmt.tprintf("could not read %s to back it up: %v",path,read_err),false }
	if err:=os.write_entire_file(saved,data); err!=nil { return fmt.tprintf("could not write %s: %v",saved,err),false }
	return "",true
}

d3_write_out :: proc(job:^Export_Job,name:string,data:[]u8) -> (msg:string,ok:bool) {
	dir,dir_msg,dir_ok:=d3_out_dir(job); if !dir_ok { return dir_msg,false }
	path,_:=filepath.join({dir,name},context.temp_allocator)
	if job.Backup {
		if backup_msg,backed_up:=d3_backup_once(path); !backed_up { return backup_msg,false }
	}
	if err:=os.write_entire_file(path,data); err!=nil { return fmt.tprintf("could not write %s: %v",path,err),false }
	return "",true
}

d3_write_collision :: proc(job:^Export_Job) -> (msg:string,ok:bool) {
	data,detail,built:=d3_collision_build(job.Collision)
	if !built { return detail,false }
	defer delete(data)
	if write_msg,written:=d3_write_out(job,"track.jpk",data); !written { return write_msg,false }
	return detail,true
}

export_dirt3 :: proc(job: ^Export_Job) -> (msg: string, ok: bool) {
	track_msg,track_ok:=d3_write_track_data(job)
	if !track_ok { return track_msg,false }
	collision_msg,collision_ok:=d3_write_collision(job)
	if !collision_ok { return collision_msg,false }
	visual_msg,visual_ok:=d3_write_routesplit(job)
	if !visual_ok { return visual_msg,false }
	vis_msg,vis_ok:=d3_write_track_vis(job)
	if !vis_ok { return vis_msg,false }
	grid_msg,grid_ok:=d3_write_grids(job)
	if !grid_ok { return grid_msg,false }
	return fmt.tprintf("%s; track.jpk: %s; routesplit.pssg: %s; track.vis: %s; grids.pssg: %s",track_msg,collision_msg,visual_msg,vis_msg,grid_msg),true
}
