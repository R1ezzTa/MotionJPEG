                case(config_pipe[3][17:16])
                    0:m_data<=center_pipe[3];
                    1:m_data<={8'd128,center_pipe[3][7:0]};
                    2:m_data<={8'd128,center_pipe[3][7:0]>=config_pipe[3][7:0]?8'd255:8'd0};
                    // Preserve edge magnitude instead of amplifying every
                    // weak/noisy edge to a full-contrast white pixel.
                    3:m_data<={8'd128,edge_strength>=config_pipe[3][15:8]?edge_strength:8'd0};
                endcase
