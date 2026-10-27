        camera_frame(0);wait(good_frames==1);
        camera_frame(0);wait(good_frames==2);
        camera_sync();camera_line(0,13);wait(bad_frames==1);
        camera_frame(1);wait(good_frames==3);wait(led[2] && !led[1]);
        repeat(3000) @(negedge clk);
        if(good_frames!=3 || bad_frames!=1 || aborts!=1 || received!=3 || dropped!=1 || overflows!=0)
            $fatal(1,"Real capture counts good=%0d bad=%0d aborts=%0d received=%0d dropped=%0d",good_frames,bad_frames,aborts,received,dropped);
