    wire source_valid=state==PSEND && (!REAL_CAMERA || camera_valid);
    wire source_sof=REAL_CAMERA?camera_sof:pixel_index==0;
    wire source_eol=REAL_CAMERA?camera_eol:x==width-1;
    wire source_eof=REAL_CAMERA?camera_eof:pixel_index==pixel_count-1;
    assign camera_take=REAL_CAMERA && state==PSEND && s_ready;
    assign camera_admit=REAL_CAMERA && state==PSEND && tables_ready && camera_ready && !busy &&
                        !stop_requested && !stop_now && !quality_pending;
