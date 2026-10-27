                    CMD_END: begin
                        if(rx_data==8'h0a) begin
                            case(command_kind)
                                1:if(DENOISE_COMMANDS) denoise_strength_requested<=pending_threshold;
                                2:if(PREPROCESS_COMMANDS) binary_threshold_requested<=pending_threshold;
                                3:if(PREPROCESS_COMMANDS && pending_threshold<4) preprocess_mode_requested<=pending_threshold[1:0];
                                4:if(PREPROCESS_COMMANDS) edge_threshold_requested<=pending_threshold;
                            endcase
                            command_state<=CMD_IDLE;
                        end else command_state<=CMD_DRAIN;
                    end
                    CMD_DRAIN: if(rx_data==8'h0a) command_state<=CMD_IDLE;
