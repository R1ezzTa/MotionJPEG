            difference<=$signed({1'b0,median})-$signed({1'b0,original2});
            weighted<=$signed({3'b0,original3,5'b10000})+
                       difference*$signed({1'b0,alpha});
            result<=weighted[12:5];
