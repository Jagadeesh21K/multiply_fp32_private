`timescale 1ns / 1ps

module multiply_fp32(
    input  wire        clk,
    input  wire        rst,
    input  wire        valid,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] z,
    output reg         out_valid
);

    reg [31:0] a_r, b_r;
    reg        busy;
    reg [2:0]  counter;

    reg               a_s, b_s, z_s;
    reg signed [10:0] a_e, b_e, exp_sum, z_e;
    reg [23:0]        a_m, b_m, z_m;

    reg [47:0] raw_product;
    reg        guard_bit, round_bit, sticky_bit;

    reg [24:0] rounded_m;
    reg [7:0]  biased_exp;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            a_r         <= 32'd0;
            b_r         <= 32'd0;
            z           <= 32'd0;
            out_valid   <= 1'b0;

            busy        <= 1'b0;
            counter     <= 3'd0;

            a_s         <= 1'b0;
            b_s         <= 1'b0;
            z_s         <= 1'b0;

            a_e         <= 11'sd0;
            b_e         <= 11'sd0;
            exp_sum     <= 11'sd0;
            z_e         <= 11'sd0;

            a_m         <= 24'd0;
            b_m         <= 24'd0;
            z_m         <= 24'd0;

            raw_product <= 48'd0;
            guard_bit   <= 1'b0;
            round_bit   <= 1'b0;
            sticky_bit  <= 1'b0;

            rounded_m   <= 25'd0;
            biased_exp  <= 8'd0;
        end else begin
            out_valid <= 1'b0;

            if (!busy) begin
                if (valid) begin
                    a_r     <= a;
                    b_r     <= b;
                    busy    <= 1'b1;
                    counter <= 3'd1;
                end
            end else begin
                case (counter)

                    // Stage 1: unpack
                    3'd1: begin
                        a_s <= a_r[31];
                        b_s <= b_r[31];

                        a_e <= $signed({3'b000, a_r[30:23]}) - 11'sd127;
                        b_e <= $signed({3'b000, b_r[30:23]}) - 11'sd127;

                        a_m <= {1'b0, a_r[22:0]};
                        b_m <= {1'b0, b_r[22:0]};

                        counter <= 3'd2;
                    end

                    // Stage 2: hidden-one insertion for normal inputs
                    3'd2: begin
                        a_m[23] <= 1'b1;
                        b_m[23] <= 1'b1;
                        z_s     <= a_s ^ b_s;
                        counter <= 3'd3;
                    end

                    // Stage 3: lightweight normalization
                    3'd3: begin
                        if ((a_m != 24'd0) && !a_m[23]) begin
                            a_m <= a_m << 1;
                            a_e <= a_e - 11'sd1;
                        end

                        if ((b_m != 24'd0) && !b_m[23]) begin
                            b_m <= b_m << 1;
                            b_e <= b_e - 11'sd1;
                        end

                        counter <= 3'd4;
                    end

                    // Stage 4: multiply core
                    3'd4: begin
                        exp_sum     <= a_e + b_e;
                        raw_product <= a_m * b_m;
                        counter     <= 3'd5;
                    end

                    // Stage 5: normalize product and extract G/R/S
                    3'd5: begin
                        if (raw_product[47]) begin
                            z_e        <= exp_sum + 11'sd1;
                            z_m        <= raw_product[47:24];
                            guard_bit  <= raw_product[23];
                            round_bit  <= raw_product[22];
                            sticky_bit <= |raw_product[21:0];
                        end else begin
                            z_e        <= exp_sum;
                            z_m        <= raw_product[46:23];
                            guard_bit  <= raw_product[22];
                            round_bit  <= raw_product[21];
                            sticky_bit <= |raw_product[20:0];
                        end

                        counter <= 3'd6;
                    end

                    // Stage 6: round-to-nearest-even
                    3'd6: begin
                        rounded_m = {1'b0, z_m};

                        if (guard_bit && (round_bit || sticky_bit || z_m[0])) begin
                            rounded_m = rounded_m + 25'd1;
                        end

                        if (rounded_m[24]) begin
                            z_m <= rounded_m[24:1];
                            z_e <= z_e + 11'sd1;
                        end else begin
                            z_m <= rounded_m[23:0];
                        end

                        counter <= 3'd7;
                    end

                    // Stage 7: pack
                    3'd7: begin
                        if (z_e > 11'sd127) begin
                            z <= {z_s, 8'hFF, 23'd0};
                        end else if (z_e < -11'sd126) begin
                            z <= {z_s, 31'd0};
                        end else begin
                            biased_exp = z_e + 11'sd127;
                            z <= {z_s, biased_exp, z_m[22:0]};
                        end

                        out_valid <= 1'b1;
                        busy      <= 1'b0;
                        counter   <= 3'd0;
                    end

                    default: begin
                        busy      <= 1'b0;
                        counter   <= 3'd0;
                        out_valid <= 1'b0;
                    end
                endcase
            end
        end
    end

endmodule