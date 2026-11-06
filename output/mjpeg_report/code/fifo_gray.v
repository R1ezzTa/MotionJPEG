    assign s_ready=wrst_n && !full;
    assign m_valid=rrst_n && !empty;
    wire write_fire=s_valid && s_ready,read_fire=m_valid && m_ready;
    wire [POINTER_BITS-1:0] wnext=wbin+write_fire,rnext=rbin+read_fire;
    wire [POINTER_BITS-1:0] wgray_next=(wnext>>1)^wnext,rgray_next=(rnext>>1)^rnext;
    wire full_next=wgray_next=={~rgray_w2[POINTER_BITS-1:POINTER_BITS-2],rgray_w2[POINTER_BITS-3:0]};
    wire empty_next=rgray_next==wgray_r2;
