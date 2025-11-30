//=====================================================
// File: pmos_sram_system.v
// Title: PMOS-Enabled Sense Amplifier SRAM System
// Description: Digital behavioral model of PMOS-enabled SRAM
// Innovation: Active-low PMOS enable for power efficiency
//=====================================================

module pmos_sram_system (
    input wire clk,
    input wire reset_n,
    input wire pre_en,           // Precharge enable (Active HIGH)
    input wire wl,               // Wordline (Active HIGH)  
    input wire sense_en_pmos,    // PMOS Sense enable (Active LOW - KEY INNOVATION)
    input wire write_en,         // Write enable (Active HIGH)
    input wire data_in,          // Data to write into SRAM
    output reg data_out,         // Data read from SRAM
    output reg operation_done,   // Operation completion flag
    output reg pmos_active,      // PMOS enable status monitor
    output reg [7:0] perf_metrics // Performance metrics
);

    //=====================================================
    // Analog Timing Parameters (Digital Modeling)
    //=====================================================
    parameter PRECHARGE_TIME = 3;        // 3ns precharge delay
    parameter SRAM_ACCESS_TIME = 2;      // 2ns SRAM access  
    parameter SENSE_AMPLIFY_TIME = 1;    // 1ns sense amp delay
    parameter BITLINE_DEV_TIME = 5;      // 5ns ΔV development
    
    // Internal signals with analog voltage representation
    reg [7:0] bl_voltage;       // Bitline voltage (0-255 = 0-2.5V)
    reg [7:0] blbar_voltage;    // Bitline bar voltage
    reg sram_cell_q;            // SRAM storage node Q
    reg sram_cell_qbar;         // SRAM storage node Qbar
    
    // Performance monitoring
    reg [15:0] sense_delay_counter;
    reg [15:0] power_estimate;
    reg sense_start_time;
    
    // Operation state machine
    reg [2:0] current_state;
    reg [15:0] state_timer;
    
    // State definitions
    localparam STATE_IDLE        = 3'b000;
    localparam STATE_PRECHARGE   = 3'b001;
    localparam STATE_ACCESS      = 3'b010; 
    localparam STATE_SENSE       = 3'b011;
    localparam STATE_COMPLETE    = 3'b100;

    //=====================================================
    // Main Operation State Machine
    //=====================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            current_state <= STATE_IDLE;
            state_timer <= 0;
            operation_done <= 0;
            sense_delay_counter <= 0;
            power_estimate <= 0;
            pmos_active <= 0;
        end else begin
            case (current_state)
                STATE_IDLE: begin
                    operation_done <= 0;
                    sense_delay_counter <= 0;
                    if (pre_en) begin
                        current_state <= STATE_PRECHARGE;
                        state_timer <= PRECHARGE_TIME;
                    end
                end
                
                STATE_PRECHARGE: begin
                    if (state_timer == 0) begin
                        current_state <= STATE_ACCESS;
                        state_timer <= BITLINE_DEV_TIME;
                    end else begin
                        state_timer <= state_timer - 1;
                    end
                end
                
                STATE_ACCESS: begin
                    if (state_timer == 0) begin
                        current_state <= STATE_SENSE;
                        state_timer <= SENSE_AMPLIFY_TIME;
                        sense_start_time <= $time;
                    end else begin
                        state_timer <= state_timer - 1;
                    end
                end
                
                STATE_SENSE: begin
                    // PMOS ENABLE ACTIVE - Key innovation point
                    pmos_active <= !sense_en_pmos;
                    
                    sense_delay_counter <= sense_delay_counter + 1;
                    if (state_timer == 0) begin
                        current_state <= STATE_COMPLETE;
                        perf_metrics[7:0] <= $time - sense_start_time;
                    end else begin
                        state_timer <= state_timer - 1;
                    end
                end
                
                STATE_COMPLETE: begin
                    operation_done <= 1;
                    current_state <= STATE_IDLE;
                end
                
                default: current_state <= STATE_IDLE;
            endcase
            
            // Power estimation (PMOS advantage: lower static power)
            if (current_state == STATE_SENSE && !sense_en_pmos) begin
                power_estimate <= power_estimate + 1;
            end
        end
    end

    //=====================================================
    // 1. Precharge Circuit Model
    //=====================================================
    always @(posedge clk) begin
        if (current_state == STATE_PRECHARGE) begin
            // Precharge both bitlines to VDD (255 = 2.5V)
            bl_voltage <= 8'd255;
            blbar_voltage <= 8'd255;
        end
    end

    //=====================================================
    // 2. 6T SRAM Cell Behavioral Model
    //=====================================================
    always @(posedge clk) begin
        if (current_state == STATE_ACCESS) begin
            if (write_en) begin
                // Write operation with access delay
                #SRAM_ACCESS_TIME;
                sram_cell_q <= data_in;
                sram_cell_qbar <= ~data_in;
                // Update bitlines for write
                bl_voltage <= data_in ? 8'd255 : 8'd0;
                blbar_voltage <= data_in ? 8'd0 : 8'd255;
            end else begin
                // Read operation: simulate bitline discharge
                if (sram_cell_q) begin
                    bl_voltage <= 8'd240;      // Slight discharge (2.35V)
                    blbar_voltage <= 8'd255;   // Maintain charge (2.5V)
                end else begin
                    bl_voltage <= 8'd255;      // Maintain charge (2.5V)
                    blbar_voltage <= 8'd240;   // Slight discharge (2.35V)
                end
            end
        end
    end

    //=====================================================
    // 3. PMOS-ENABLED SENSE AMPLIFIER (KEY INNOVATION)
    //=====================================================
    always @(posedge clk) begin
        if (current_state == STATE_SENSE && !sense_en_pmos) begin
            // PMOS HEADER ACTIVE - Sense amplifier powered
            #SENSE_AMPLIFY_TIME;
            
            // Voltage comparison with 40mV threshold (8'd10 in our scale)
            if (bl_voltage > (blbar_voltage + 8'd10)) begin 
                data_out <= 1'b1;
                // Amplification to full swing
                bl_voltage <= 8'd255;   // VDD level
                blbar_voltage <= 8'd0;  // GND level
            end else if (blbar_voltage > (bl_voltage + 8'd10)) begin
                data_out <= 1'b0;
                bl_voltage <= 8'd0;     // GND level
                blbar_voltage <= 8'd255; // VDD level
            end else begin
                data_out <= 1'bx; // Undefined for small differences
            end
        end
    end

    //=====================================================
    // 4. Performance Metrics Collection
    //=====================================================
    always @(posedge clk) begin
        if (current_state == STATE_COMPLETE) begin
            perf_metrics[15:8] <= power_estimate;
        end
    end
    
    //=====================================================
    // 5. Voltage Sensitivity Monitor
    //=====================================================
    wire [7:0] voltage_delta;
    assign voltage_delta = (bl_voltage > blbar_voltage) ? 
                          (bl_voltage - blbar_voltage) : 
                          (blbar_voltage - bl_voltage);
    
    // Sensitivity threshold indicator
    reg adequate_delta_v;
    always @* begin
        adequate_delta_v = (voltage_delta >= 8'd20); // ~40mV threshold
    end

endmodule
